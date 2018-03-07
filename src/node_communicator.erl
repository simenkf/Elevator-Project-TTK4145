%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% This module handles all communication between seperate nodes, i.e. every message  %%
%% from node A to node B is sent from this module on node A and received in the very %%
%% same module on node B. It is then locally routed to the correct module.           %%
%%    The module consists in essence of only one funciton which operates as a main   %%
%% loop taking a list as argument. The list contains all locally known orders. The   %%
%% list is reguallarly shared (and taken the union of) between different nodes to    %%
%% avoid missing orders.                                                             %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(node_communicator).
-export([node_communicator/0]).

% TODO: spawn from gloabl spawner, remember there is only coments for LED now
% TODO: remove unnecessary comments

node_communicator() ->
    driver ! turn_off_all_leds,
    node_communicator([]).

node_communicator(LocalOrderList) ->
    io:format("LocalOrderList: ~p\n", [LocalOrderList]),

    receive
        {new_order, Order} when is_tuple(Order) ->
            io:format("Received: new_order\n"),
            case lists:member(Order, LocalOrderList) of
                true  -> node_communicator(LocalOrderList);
                false -> 
                    lists:foreach(fun(Node) -> {order_manager, Node} ! {add_order, Order, LocalOrderList, node()} end, nodes()),
                    order_manager ! {add_order, Order, LocalOrderList, node()},                                                                 %%%%%%%%%%%% debug
                    node_communicator(LocalOrderList)     
            end;

        {add_order, Order, ExternalOrderList, ExternalElevator}
        when is_tuple(Order) andalso is_list(ExternalOrderList) ->
            io:format("Received: add_order~p\n", [Order]),
            {order_manager, ExternalElevator} ! {ack_order, Order, LocalOrderList, node()},
            MissingOrders = ExternalOrderList -- LocalOrderList,
            node_communicator(LocalOrderList ++ MissingOrders ++ [Order]);

        {ack_order, Order, ExternalOrderList, ExternalElevator}
        when is_tuple(Order) andalso is_list(ExternalOrderList)  ->
            io:format("Received: ack_order\n"),
            {order_manager, ExternalElevator} ! {led_on, Order},
            {Button_type, Floor} = Order,
            driver ! {set_order_button_LED, Button_type, Floor, on},
            io:format("LED turned ON for order ~p\n", [Order]),
            MissingOrders = ExternalOrderList -- LocalOrderList,
            node_communicator(LocalOrderList ++ MissingOrders ++ [Order]);
        
        {order_finished, Order} when is_tuple(Order) ->
            io:format("Received: order_finished\n"),
            lists:foreach(fun(Node) -> {order_manager, Node} ! {remove_order, Order, LocalOrderList} end, [node()|nodes()]),
            node_communicator(LocalOrderList);

        {remove_order, Order, ExternalOrderList} when is_tuple(Order) andalso is_list(ExternalOrderList) ->
            io:format("Received: remove_order\n"),
            {Button_type, Floor} = Order,
            driver ! {set_order_button_LED, Button_type, Floor, off},
            io:format("LED turned OFF for order ~p\n", [Order]),
            MissingOrders = ExternalOrderList -- LocalOrderList,
            %%%%%% TODO: REMEMBER TO REMOVE ALL ORDERS AT THAT FLOOR %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            node_communicator([X || X <- LocalOrderList ++ MissingOrders, X /= Order]); % removes all instances of Order
        
        {led_on, Order} when is_tuple(Order) ->
            io:format("Received: led_on\n"),
            {Button_type, Floor} = Order,
            driver ! {set_order_button_LED, Button_type, Floor, on},
            io:format("LEDs turned ON for order ~p\n", [Order]),
            node_communicator(LocalOrderList);

        {get_orderlist, PID} when is_pid(PID) ->
            io:format("Received: get_orderList\n"),
            PID ! LocalOrderList,
            node_communicator(LocalOrderList);

        % Function for debug use only, to be removed!
        
        reset ->
           lists:foreach(fun(Node) -> {order_manager, Node} ! reset_queue_and_button_leds end, nodes()),
            order_manager ! reset_queue_and_button_leds,
            node_communicator([]);

        reset_queue_and_button_leds ->
            driver ! turn_off_all_leds,
            node_communicator([]);

    Unexpected ->
            io:format("Unexpected message in node_communicator: ~p~n", [Unexpected]),
            node_communicator(LocalOrderList)
    end.