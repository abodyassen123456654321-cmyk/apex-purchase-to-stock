-- P2S Purchase-to-Stock
-- P2S_STOCK (stock movements and balances)

create or replace package p2s_stock as

    procedure post_movement (
        p_movement_type in varchar2,
        p_warehouse_id  in number,
        p_item_id       in number,
        p_quantity      in number,
        p_ref_type      in varchar2 default null,
        p_ref_id        in number   default null,
        p_reason        in varchar2 default null);

    procedure adjust_stock (
        p_warehouse_id in number,
        p_item_id      in number,
        p_quantity     in number,
        p_reason       in varchar2);

    function get_on_hand (
        p_warehouse_id in number,
        p_item_id      in number) return number;

end p2s_stock;
/

create or replace package body p2s_stock as

    c_module constant varchar2(30) := 'P2S_STOCK.';

    procedure post_movement (
        p_movement_type in varchar2,
        p_warehouse_id  in number,
        p_item_id       in number,
        p_quantity      in number,
        p_ref_type      in varchar2 default null,
        p_ref_id        in number   default null,
        p_reason        in varchar2 default null)
    is
        l_signed  number;
        l_balance number;
    begin
        if p_quantity is null or p_quantity <= 0 then
            p2s_err.raise_error('Movement quantity must be greater than zero.');
        end if;

        l_signed := case
                        when p_movement_type in ('RECEIPT', 'ADJUST_IN')  then  p_quantity
                        when p_movement_type in ('ISSUE',   'ADJUST_OUT') then -p_quantity
                    end;
        if l_signed is null then
            p2s_err.raise_error('Invalid movement type: ' || p_movement_type || '.');
        end if;

        begin
            insert into p2s_stock_balances (warehouse_id, item_id, qty_on_hand)
            values (p_warehouse_id, p_item_id, 0);
        exception
            when dup_val_on_index then
                null;
        end;

        select qty_on_hand
          into l_balance
          from p2s_stock_balances
         where warehouse_id = p_warehouse_id
           and item_id      = p_item_id
           for update;

        if l_balance + l_signed < 0 then
            p2s_err.raise_error('Not enough stock. Available: ' || l_balance
                                || ', requested: ' || p_quantity || '.');
        end if;

        l_balance := l_balance + l_signed;

        update p2s_stock_balances
           set qty_on_hand = l_balance
         where warehouse_id = p_warehouse_id
           and item_id      = p_item_id;

        insert into p2s_stock_movements
            (movement_type, warehouse_id, item_id, quantity, balance_after, ref_type, ref_id, reason)
        values
            (p_movement_type, p_warehouse_id, p_item_id, l_signed, l_balance, p_ref_type, p_ref_id, p_reason);

    exception
        when others then
            p2s_err.log_error(c_module || 'POST_MOVEMENT',
                'type=' || p_movement_type || ' wh=' || p_warehouse_id
                || ' item=' || p_item_id || ' qty=' || p_quantity);
            raise;
    end post_movement;

    procedure adjust_stock (
        p_warehouse_id in number,
        p_item_id      in number,
        p_quantity     in number,
        p_reason       in varchar2)
    is
        l_active varchar2(1);
    begin
        p2s_app.require_role('STOREKEEPER');

        if p_quantity is null or p_quantity = 0 then
            p2s_err.raise_error('Adjustment quantity cannot be zero.');
        end if;
        if trim(p_reason) is null then
            p2s_err.raise_error('A reason is required for stock adjustments.');
        end if;

        begin
            select is_active into l_active from p2s_items where item_id = p_item_id;
        exception
            when no_data_found then
                p2s_err.raise_error('Item not found.');
        end;
        if l_active <> 'Y' then
            p2s_err.raise_error('Inactive items cannot be adjusted.');
        end if;

        post_movement(
            p_movement_type => case when p_quantity > 0 then 'ADJUST_IN' else 'ADJUST_OUT' end,
            p_warehouse_id  => p_warehouse_id,
            p_item_id       => p_item_id,
            p_quantity      => abs(p_quantity),
            p_ref_type      => 'ADJ',
            p_reason        => p_reason);

    exception
        when others then
            p2s_err.log_error(c_module || 'ADJUST_STOCK',
                'wh=' || p_warehouse_id || ' item=' || p_item_id || ' qty=' || p_quantity);
            raise;
    end adjust_stock;

    function get_on_hand (
        p_warehouse_id in number,
        p_item_id      in number) return number
    is
        l_qty number;
    begin
        select qty_on_hand
          into l_qty
          from p2s_stock_balances
         where warehouse_id = p_warehouse_id
           and item_id      = p_item_id;
        return l_qty;
    exception
        when no_data_found then
            return 0;
    end get_on_hand;

end p2s_stock;
/

select object_name, object_type, status
  from user_objects
 where object_name = 'P2S_STOCK';
