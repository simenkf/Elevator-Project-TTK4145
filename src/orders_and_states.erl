%%=================================================================================================
%% This module stores and maintains known orders and states.
%%=================================================================================================

-module(orders_and_states).
-export([start/0]).
-include("parameters.hrl").

-define(RETRY_ASSIGNING_PERIOD,   300).
-define(PRINT_ORDER_LIST_PERIOD, 3000).
-record(orders, {assigned = [], unassigned = [], cab = []}).
-record(state,  {movement, floor, assigned_order = none}).

%% Vi kan lage en prosess som sender mld til odata_mgr om å printe ordrelisten, typ en gang i sekudnet elns? Eller vil vi det?

start() ->
    timer:sleep(200),  % Sleep to better align PID prints at start up. None other uses and can thus be safely removed.
    Existing_cab_orders = recover_cab_orders(),
    fsm ! {update_order_list, Existing_cab_orders#orders.cab},
    spawn(fun() -> periodically_print_order_list() end),
    main_loop(Existing_cab_orders, dict:new()).

main_loop(Orders, States) ->
    receive

        %----------------------------------------------------------------------------------------------
        % Prints assigned, unassigned and cab orders. Periodically called by looping spawned process.
        %----------------------------------------------------------------------------------------------
        print_order_list ->
            io:format("Assigned: ~p          Unassigned: ~p          Cab orders: ~p\n",
            [Orders#orders.assigned, Orders#orders.unassigned, Orders#orders.cab]),
            main_loop(Orders, States);



        %----------------------------------------------------------------------------------------------
        % Acknowledge the order and append it to correspoding list of 'Orders' if not already present.
        %----------------------------------------------------------------------------------------------
        {add_order, {cab_button, Floor}} ->
            communicator ! {set_order_button_LED, on, {cab_button, Floor}},
            case lists:member({cab_button, Floor}, Orders#orders.cab) of
                true  ->  % Already existing cab order
                    main_loop(Orders, States);
                false ->  % New cab order
                    Updated_orders = Orders#orders{cab = Orders#orders.cab ++ [{cab_button, Floor}]},
                    fsm ! {update_order_list, Updated_orders#orders.cab ++ Updated_orders#orders.unassigned},
                    write_cab_order_to_file(Floor),
                    main_loop(Updated_orders, States)
            end;

        {add_order, Hall_order, From_node} ->
            case From_node == node() of
                true  -> no_ack;  % Does not send acknowledge when it is to be added locally only
                false -> communicator ! {order_added, Hall_order, From_node}
            end,

            All_hall_orders = Orders#orders.unassigned ++ lists:map(fun({Order, _Node}) -> Order end, Orders#orders.assigned),

            case lists:member(Hall_order, All_hall_orders) of
                true  ->  % Already existing hall order, either assigned or unassigned
                    main_loop(Orders, States);
                false ->  % New hall order
                    Updated_orders = Orders#orders{unassigned = Orders#orders.unassigned ++ [Hall_order]},
                    fsm ! {update_order_list, Updated_orders#orders.cab ++ Updated_orders#orders.unassigned},
                    main_loop(Updated_orders, States)
            end;



        %----------------------------------------------------------------------------------------------
        % Assigns an order to 'fsm'. If none orders are available it tries again periodically.
        %----------------------------------------------------------------------------------------------
        assign_order_to_fsm ->
            case lists:keyfind(node(), 2, Orders#orders.assigned) of
                {Already_assigned_order, _Node} ->  % Order already assigned to this node
                    fsm ! {assigned_order, Already_assigned_order, Orders#orders.cab ++ Orders#orders.unassigned},
                    main_loop(Orders, States);
                false ->
                    continue
                end,

            case Orders#orders.cab of
                [Cab_order|Remaining_cab_orders] ->  % Prioritize cab orders
                    communicator ! {new_order_assigned, Cab_order},
                    fsm          ! {assigned_order, Cab_order, Remaining_cab_orders ++ Orders#orders.unassigned};
                [] ->  % No cab orders available
                    case scheduler:get_most_efficient_order(Orders#orders.unassigned, States) of
                        no_orders_available ->
                            spawn(fun() -> timer:sleep(?RETRY_ASSIGNING_PERIOD), data_manager ! assign_order_to_fsm end);
                        Hall_order ->
                            communicator ! {new_order_assigned, Hall_order},
                            fsm          ! {assigned_order, Hall_order, Orders#orders.cab ++ Orders#orders.unassigned -- [Hall_order]}
                    end
            end,
            main_loop(Orders, States);



        %----------------------------------------------------------------------------------------------
        % Mark order as assigned, moving it from unassigned to assigned of 'Orders'.
        %----------------------------------------------------------------------------------------------
        {mark_order_assigned, Order, Node} ->
            %{ok, State} = dict:find(Node, States),
            %Updated_states = dict:store(Node, State#state{assigned_order = Order}),
            io:format("~s ORDER = ~p     NODE = ~p\n", [color:redb("MARK ORDER ASSIGNED:"), Order, Node]),
            io:format("######################################1 ~p\n######################################\n", [States]),
            Updated_states = dict:update(Node, fun(Old_state) -> Old_state#state{assigned_order = Order} end, States),
            io:format("######################################2 ~p\n######################################\n", [States]),
            case element(1, Order) of
                cab_button   -> main_loop(Orders, Updated_states);  % Only assigned hall orders are moved to 'assigned' of 'Orders'
                _Hall_button -> continue
            end,

            case lists:member({Order, Node}, Orders#orders.assigned) of
                true ->  % Order aldready assigned to some node
                    main_loop(Orders, States);
                false ->
                    Updated_assigned_hall_orders   = Orders#orders.assigned   ++ [{Order, Node}],
                    Updated_unassigned_hall_orders = Orders#orders.unassigned -- [Order],
                    Updated_orders                 = Orders#orders{unassigned =  Updated_unassigned_hall_orders,
                                                                     assigned =  Updated_assigned_hall_orders},
                    watchdog ! {start_watching_order, Order},
                    fsm      ! {update_order_list, Orders#orders.cab ++ Updated_unassigned_hall_orders},
                    main_loop(Updated_orders, Updated_states)
            end;
        


        %----------------------------------------------------------------------------------------------
        % Move 'Hall_order' from being assigned back to the list of unassigned 'Orders'.
        %----------------------------------------------------------------------------------------------
        {unmark_order_assigned, Hall_order} -> % Happens when an assigned order times out
            Should_keep_order_in_list      = fun(Assigned_order) -> element(1, Assigned_order) /= Hall_order end,
            Updated_assigned_hall_orders   = lists:filter(Should_keep_order_in_list, Orders#orders.assigned),
            Updated_unassigned_hall_orders = [Hall_order] ++ Orders#orders.unassigned,
            Updated_orders                 = Orders#orders{unassigned = Updated_unassigned_hall_orders,
                                                             assigned = Updated_assigned_hall_orders},                                                             
            suspend_fsm_if_order_was_locally_assigned(Hall_order, Orders, Updated_orders),
            main_loop(Updated_orders, States);



        %----------------------------------------------------------------------------------------------
        % Removes an order from 'Orders'.
        %----------------------------------------------------------------------------------------------
        {remove_order, {cab_button, Floor}} ->
            Updated_cab_orders = Orders#orders.cab -- [{cab_button, Floor}],
            Updated_orders     = Orders#orders{cab =  Updated_cab_orders},
            fsm ! {update_order_list, Updated_cab_orders  ++ Updated_orders#orders.unassigned},
            remove_cab_order_from_file(Floor),
            main_loop(Updated_orders, States);

        {remove_order, Hall_order} ->
            cancel_order_if_assigned_locally(Hall_order, Orders), % Notifies 'fsm' that the 'Hall_order' is served by perhaps another node
            Should_keep_order_in_list      = fun(Assigned_order) -> element(1, Assigned_order) /= Hall_order end,
            Updated_assigned_hall_orders   = lists:filter(Should_keep_order_in_list, Orders#orders.assigned),
            Updated_unassigned_hall_orders = Orders#orders.unassigned -- [Hall_order],
            Updated_orders                 = Orders#orders{unassigned =  Updated_unassigned_hall_orders,
                                                             assigned =  Updated_assigned_hall_orders},
            watchdog ! {stop_watching_order, Hall_order},
            fsm      ! {update_order_list, Orders#orders.cab ++ Updated_unassigned_hall_orders},
            main_loop(Updated_orders, States);



        %----------------------------------------------------------------------------------------------
        % Updates state of 'Node' in 'States', adding it if not already present.
        %----------------------------------------------------------------------------------------------
        {update_state, Node, New_state} when Node == node() andalso New_state#state.movement == idle ->
            Updated_states = dict:store(Node, New_state, States),
            data_manager ! assign_order_to_fsm,
            main_loop(Orders, Updated_states);

        {update_state, Node, New_state} ->
            Updated_states = dict:store(Node, New_state, States),
            main_loop(Orders, Updated_states);



        %----------------------------------------------------------------------------------------------
        % Moves orders assigned to 'Node' to the the front of the list of unassigend orders of 'Orders'
        %----------------------------------------------------------------------------------------------
        {node_down, Node} ->
            Orders_assigned_to_offline_node = lists:filter(fun({_Order, Assigned_node}) -> Assigned_node == Node end, Orders#orders.assigned),
            Hall_orders_extracted           = lists:map(fun({Order, _Node}) -> Order end, Orders_assigned_to_offline_node),
            Updated_assigned_hall_orders    = Orders#orders.assigned -- Orders_assigned_to_offline_node,
            Updated_unassigned_hall_orders  = Hall_orders_extracted ++ Orders#orders.unassigned,
            Updated_orders                  = Orders#orders{unassigned = Updated_unassigned_hall_orders,
                                                              assigned = Updated_assigned_hall_orders},
            lists:foreach(fun(Hall_order) -> watchdog ! {stop_watching_order, Hall_order} end, Hall_orders_extracted),
            fsm ! {update_order_list, Orders#orders.cab ++ Updated_unassigned_hall_orders},
            main_loop(Updated_orders, States);
        


        %----------------------------------------------------------------------------------------------
        % Sends/receives a copy of existing hall orders and current states to the newly connected node.
        %----------------------------------------------------------------------------------------------
        {node_up, New_node} ->
            communicator ! {sync_data_with_new_node, New_node, Orders#orders.assigned, Orders#orders.unassigned, States},
            Updated_states = dict:store(New_node, #state{movement = uninitialized, floor = undefined, assigned_order = none}, States),
            main_loop(Orders, Updated_states);

        {existing_data, Updated_assigned_hall_orders, Updated_unassigned_hall_orders, Updated_states} ->
            fsm ! {update_order_list, Orders#orders.cab ++ Updated_unassigned_hall_orders},
            lists:foreach(fun({Order, _Node})   -> watchdog     ! {start_watching_order, Order} end, Updated_assigned_hall_orders),

            Assigned_hall_orders_extracted = lists:map(fun({Order, _Node}) -> Order end, Updated_assigned_hall_orders),
            lists:foreach(fun(Cab_order)             -> communicator ! {set_order_button_LED, on, Cab_order}             end, Orders#orders.cab),
            lists:foreach(fun(Assigned_hall_order)   -> communicator ! {set_order_button_LED, on, Assigned_hall_order}   end, Assigned_hall_orders_extracted),
            lists:foreach(fun(Unassigned_hall_order) -> communicator ! {set_order_button_LED, on, Unassigned_hall_order} end, Updated_unassigned_hall_orders),
            
            Collision_handler = fun(_Node, State1, _State2) -> State1 end,  % If a key-value pair is present in both dicts, choose the former
            Merged_states = dict:merge(Collision_handler, States, Updated_states),

            Updated_orders = Orders#orders{assigned = Updated_assigned_hall_orders, unassigned = Updated_unassigned_hall_orders},
            main_loop(Updated_orders, Merged_states);



        Unexpected ->
            io:format("~s Unexpected message: ~p.\n", [color:red("Orders_and_states:"), Unexpected]),
            main_loop(Orders, States)

    end.



%----------------------------------------------------------------------------------------------
% File I/O functions storing/reading local cab orders to a dets file.
%----------------------------------------------------------------------------------------------
recover_cab_orders() ->
    Cab_orders = get_existing_cab_orders_from_file(),
    lists:foreach(fun(Cab_order) -> communicator ! {set_order_button_LED, on, Cab_order} end, Cab_orders),
    #orders{cab = Cab_orders}.



get_existing_cab_orders_from_file() ->
    File_name = list_to_atom("elevator@" ++ node_connection:get_IP()),
    dets:open_file(File_name, [{type, bag}]),
    Cab_orders = dets:lookup(File_name, cab_button),
    dets:close(File_name),
    Cab_orders.



write_cab_order_to_file(Floor) ->
    File_name = node(),
    dets:open_file(File_name, [{type, bag}]),
    dets:insert(File_name, {cab_button, Floor}),
    dets:close(File_name).



remove_cab_order_from_file(Floor) ->
    File_name = node(),
    dets:open_file(File_name, [{type, bag}]),
    dets:delete_object(File_name, {cab_button, Floor}),
    dets:close(File_name).



%----------------------------------------------------------------------------------------------
% If 'Hall_order' is assigned to the local node, 'fsm' is notified that the order is served in
% case of another node being the elevator who served the order, canceling 'fsms' destination.
%----------------------------------------------------------------------------------------------
cancel_order_if_assigned_locally(Hall_order, Orders) ->
    Orders_assigned_to_local_node  = lists:filter(fun({_Order, Assigned_node}) -> Assigned_node == node() end, Orders#orders.assigned),
    Assigned_hall_orders_extracted = lists:map(fun({Order, _Node}) -> Order end, Orders_assigned_to_local_node),
    case lists:member(Hall_order, Assigned_hall_orders_extracted) of
        true  -> fsm ! cancel_assigned_order;
        false -> ignore
    end.


suspend_fsm_if_order_was_locally_assigned(Hall_order, Orders, Updated_orders) ->
    Orders_assigned_to_local_node  = lists:filter(fun({_Order, Assigned_node}) -> Assigned_node == node() end, Orders#orders.assigned),
    Assigned_hall_orders_extracted = lists:map(fun({Order, _Node}) -> Order end, Orders_assigned_to_local_node),
    case lists:member(Hall_order, Assigned_hall_orders_extracted) of
        true  -> fsm ! timeout_order, watchdog ! stop_watching_movement;
        false -> fsm ! {update_order_list, Updated_orders#orders.cab ++ Updated_orders#orders.unassigned}
    end.



%----------------------------------------------------------------------------------------------
% Looping spawned proccess requesting 'data_manager' to print the order list.
%----------------------------------------------------------------------------------------------
periodically_print_order_list() ->
    timer:sleep(?PRINT_ORDER_LIST_PERIOD),
    data_manager ! print_order_list,
    periodically_print_order_list().