-- P2S Purchase-to-Stock
-- P2S_PURCHASE (PR, approvals, PO, goods receipt)

create or replace package p2s_purchase as

    function create_pr (
        p_warehouse_id   in number,
        p_needed_by_date in date     default null,
        p_justification  in varchar2 default null) return number;

    procedure add_pr_line (
        p_pr_id          in number,
        p_item_id        in number,
        p_quantity       in number,
        p_est_unit_price in number default null);

    procedure update_pr_line (
        p_pr_line_id     in number,
        p_quantity       in number,
        p_est_unit_price in number);

    procedure delete_pr_line (p_pr_line_id in number);

    procedure submit_pr  (p_pr_id in number);
    procedure approve_pr (p_pr_id in number, p_comments in varchar2 default null);
    procedure reject_pr  (p_pr_id in number, p_comments in varchar2);
    procedure cancel_pr  (p_pr_id in number);

    function create_po_from_pr (
        p_pr_id         in number,
        p_supplier_id   in number,
        p_expected_date in date default null) return number;

    function create_grn (
        p_po_id in number,
        p_notes in varchar2 default null) return number;

    procedure add_grn_line (
        p_grn_id     in number,
        p_po_line_id in number,
        p_qty        in number);

    procedure post_grn (p_grn_id in number);

end p2s_purchase;
/

create or replace package body p2s_purchase as

    c_module constant varchar2(30) := 'P2S_PURCHASE.';

    procedure fail (p_message in varchar2) is
    begin
        p2s_err.raise_error(p_message);
    end fail;

    function next_doc_no (p_doc_type in varchar2) return varchar2 is
        l_seq number;
    begin
        case p_doc_type
            when 'PR'  then l_seq := p2s_pr_no_seq.nextval;
            when 'PO'  then l_seq := p2s_po_no_seq.nextval;
            when 'GRN' then l_seq := p2s_grn_no_seq.nextval;
        end case;
        return p_doc_type || '-' || to_char(sysdate, 'YYYY') || '-' || lpad(l_seq, 5, '0');
    end next_doc_no;

    function lock_pr (p_pr_id in number) return p2s_pr_headers%rowtype is
        l_pr p2s_pr_headers%rowtype;
    begin
        select *
          into l_pr
          from p2s_pr_headers
         where pr_id = p_pr_id
           for update;
        return l_pr;
    exception
        when no_data_found then
            fail('Purchase request not found.');
            return null;
    end lock_pr;

    procedure recalc_pr_total (p_pr_id in number) is
    begin
        update p2s_pr_headers h
           set total_amount = (select coalesce(sum(l.line_amount), 0)
                                 from p2s_pr_lines l
                                where l.pr_id = h.pr_id)
         where h.pr_id = p_pr_id;
    end recalc_pr_total;

    procedure assert_pr_editable (p_pr in p2s_pr_headers%rowtype) is
    begin
        if p_pr.status <> 'DRAFT' then
            fail('Only DRAFT requests can be changed. Current status: ' || p_pr.status || '.');
        end if;
        if p_pr.requester_id <> p2s_app.current_user_id
           and not p2s_app.has_role('ADMIN')
        then
            fail('Only the requester can change this request.');
        end if;
    end assert_pr_editable;

    function pr_id_of_line (p_pr_line_id in number) return number is
        l_pr_id number;
    begin
        select pr_id into l_pr_id from p2s_pr_lines where pr_line_id = p_pr_line_id;
        return l_pr_id;
    exception
        when no_data_found then
            fail('Request line not found.');
            return null;
    end pr_id_of_line;

    procedure act_on_pr (
        p_pr_id    in number,
        p_action   in varchar2,
        p_comments in varchar2)
    is
        l_pr      p2s_pr_headers%rowtype;
        l_appr    p2s_pr_approvals%rowtype;
        l_user_id number;
        l_pending number;
    begin
        l_pr := lock_pr(p_pr_id);

        if l_pr.status <> 'SUBMITTED' then
            fail('Only SUBMITTED requests can be approved or rejected. Current status: ' || l_pr.status || '.');
        end if;

        l_user_id := p2s_app.current_user_id;

        if l_pr.requester_id = l_user_id then
            fail('You cannot approve or reject your own request.');
        end if;

        begin
            select *
              into l_appr
              from p2s_pr_approvals
             where pr_id = p_pr_id
               and approval_level = (select min(approval_level)
                                       from p2s_pr_approvals
                                      where pr_id  = p_pr_id
                                        and status = 'PENDING');
        exception
            when no_data_found then
                fail('No pending approval step was found for this request.');
        end;

        if not p2s_app.has_role(l_appr.approver_role) then
            fail('Approval level ' || l_appr.approval_level || ' requires the '
                 || l_appr.approver_role || ' role.');
        end if;

        if p_action = 'REJECTED' and trim(p_comments) is null then
            fail('A reason is required when rejecting.');
        end if;

        update p2s_pr_approvals
           set status       = p_action,
               action_by_id = l_user_id,
               action_on    = systimestamp,
               comments     = p_comments
         where approval_id  = l_appr.approval_id;

        if p_action = 'REJECTED' then
            update p2s_pr_headers set status = 'REJECTED' where pr_id = p_pr_id;
        else
            select count(*)
              into l_pending
              from p2s_pr_approvals
             where pr_id  = p_pr_id
               and status = 'PENDING';

            if l_pending = 0 then
                update p2s_pr_headers set status = 'APPROVED' where pr_id = p_pr_id;
            end if;
        end if;
    end act_on_pr;

    function create_pr (
        p_warehouse_id   in number,
        p_needed_by_date in date     default null,
        p_justification  in varchar2 default null) return number
    is
        l_id        number;
        l_pr_number p2s_pr_headers.pr_number%type;
        l_user_id   number;
        l_active    varchar2(1);
    begin
        l_user_id := p2s_app.current_user_id;

        begin
            select is_active into l_active from p2s_warehouses where warehouse_id = p_warehouse_id;
        exception
            when no_data_found then
                fail('Please select a valid warehouse.');
        end;
        if l_active <> 'Y' then
            fail('The selected warehouse is inactive.');
        end if;

        l_pr_number := next_doc_no('PR');

        insert into p2s_pr_headers
            (pr_number, requester_id, warehouse_id, needed_by_date, justification)
        values
            (l_pr_number, l_user_id, p_warehouse_id, p_needed_by_date, p_justification)
        returning pr_id into l_id;

        return l_id;
    exception
        when others then
            p2s_err.log_error(c_module || 'CREATE_PR', 'wh=' || p_warehouse_id);
            raise;
    end create_pr;

    procedure add_pr_line (
        p_pr_id          in number,
        p_item_id        in number,
        p_quantity       in number,
        p_est_unit_price in number default null)
    is
        l_pr      p2s_pr_headers%rowtype;
        l_price   number;
        l_active  varchar2(1);
        l_line_no number;
    begin
        l_pr := lock_pr(p_pr_id);
        assert_pr_editable(l_pr);

        if p_quantity is null or p_quantity <= 0 then
            fail('Quantity must be greater than zero.');
        end if;
        if p_est_unit_price < 0 then
            fail('Price cannot be negative.');
        end if;

        begin
            select standard_price, is_active
              into l_price, l_active
              from p2s_items
             where item_id = p_item_id;
        exception
            when no_data_found then
                fail('Please select a valid item.');
        end;
        if l_active <> 'Y' then
            fail('This item is inactive and cannot be requested.');
        end if;

        l_price := coalesce(p_est_unit_price, l_price);

        select coalesce(max(line_no), 0) + 1
          into l_line_no
          from p2s_pr_lines
         where pr_id = p_pr_id;

        insert into p2s_pr_lines (pr_id, line_no, item_id, quantity, est_unit_price)
        values (p_pr_id, l_line_no, p_item_id, p_quantity, l_price);

        recalc_pr_total(p_pr_id);
    exception
        when others then
            p2s_err.log_error(c_module || 'ADD_PR_LINE',
                'pr=' || p_pr_id || ' item=' || p_item_id || ' qty=' || p_quantity);
            raise;
    end add_pr_line;

    procedure update_pr_line (
        p_pr_line_id     in number,
        p_quantity       in number,
        p_est_unit_price in number)
    is
        l_pr_id number;
        l_pr    p2s_pr_headers%rowtype;
    begin
        l_pr_id := pr_id_of_line(p_pr_line_id);
        l_pr    := lock_pr(l_pr_id);
        assert_pr_editable(l_pr);

        if p_quantity is null or p_quantity <= 0 then
            fail('Quantity must be greater than zero.');
        end if;
        if p_est_unit_price is null or p_est_unit_price < 0 then
            fail('Price is required and cannot be negative.');
        end if;

        update p2s_pr_lines
           set quantity       = p_quantity,
               est_unit_price = p_est_unit_price
         where pr_line_id     = p_pr_line_id;

        recalc_pr_total(l_pr_id);
    exception
        when others then
            p2s_err.log_error(c_module || 'UPDATE_PR_LINE', 'line=' || p_pr_line_id);
            raise;
    end update_pr_line;

    procedure delete_pr_line (p_pr_line_id in number) is
        l_pr_id number;
        l_pr    p2s_pr_headers%rowtype;
    begin
        l_pr_id := pr_id_of_line(p_pr_line_id);
        l_pr    := lock_pr(l_pr_id);
        assert_pr_editable(l_pr);

        delete from p2s_pr_lines where pr_line_id = p_pr_line_id;

        recalc_pr_total(l_pr_id);
    exception
        when others then
            p2s_err.log_error(c_module || 'DELETE_PR_LINE', 'line=' || p_pr_line_id);
            raise;
    end delete_pr_line;

    procedure submit_pr (p_pr_id in number) is
        l_pr     p2s_pr_headers%rowtype;
        l_lines  number;
        l_levels number;
    begin
        l_pr := lock_pr(p_pr_id);
        assert_pr_editable(l_pr);

        select count(*) into l_lines from p2s_pr_lines where pr_id = p_pr_id;
        if l_lines = 0 then
            fail('Add at least one line before submitting.');
        end if;
        if l_pr.total_amount <= 0 then
            fail('The request total must be greater than zero.');
        end if;

        insert into p2s_pr_approvals (pr_id, approval_level, approver_role, status)
        select p_pr_id, r.approval_level, r.approver_role, 'PENDING'
          from p2s_approval_rules r
         where r.is_active = 'Y'
           and l_pr.total_amount > r.threshold_amount;

        l_levels := sql%rowcount;
        if l_levels = 0 then
            fail('No approval rule applies to this request. Please check the approval matrix.');
        end if;

        update p2s_pr_headers
           set status       = 'SUBMITTED',
               submitted_on = systimestamp
         where pr_id        = p_pr_id;
    exception
        when others then
            p2s_err.log_error(c_module || 'SUBMIT_PR', 'pr=' || p_pr_id);
            raise;
    end submit_pr;

    procedure approve_pr (p_pr_id in number, p_comments in varchar2 default null) is
    begin
        act_on_pr(p_pr_id, 'APPROVED', p_comments);
    exception
        when others then
            p2s_err.log_error(c_module || 'APPROVE_PR', 'pr=' || p_pr_id);
            raise;
    end approve_pr;

    procedure reject_pr (p_pr_id in number, p_comments in varchar2) is
    begin
        act_on_pr(p_pr_id, 'REJECTED', p_comments);
    exception
        when others then
            p2s_err.log_error(c_module || 'REJECT_PR', 'pr=' || p_pr_id);
            raise;
    end reject_pr;

    procedure cancel_pr (p_pr_id in number) is
        l_pr p2s_pr_headers%rowtype;
    begin
        l_pr := lock_pr(p_pr_id);

        if l_pr.status not in ('DRAFT', 'SUBMITTED') then
            fail('Only DRAFT or SUBMITTED requests can be cancelled. Current status: ' || l_pr.status || '.');
        end if;
        if l_pr.requester_id <> p2s_app.current_user_id
           and not p2s_app.has_role('ADMIN')
        then
            fail('Only the requester can cancel this request.');
        end if;

        delete from p2s_pr_approvals where pr_id = p_pr_id and status = 'PENDING';

        update p2s_pr_headers set status = 'CANCELLED' where pr_id = p_pr_id;
    exception
        when others then
            p2s_err.log_error(c_module || 'CANCEL_PR', 'pr=' || p_pr_id);
            raise;
    end cancel_pr;

    function create_po_from_pr (
        p_pr_id         in number,
        p_supplier_id   in number,
        p_expected_date in date default null) return number
    is
        l_pr        p2s_pr_headers%rowtype;
        l_po_id     number;
        l_po_number p2s_po_headers.po_number%type;
        l_active    varchar2(1);
    begin
        p2s_app.require_role('FINANCE');

        l_pr := lock_pr(p_pr_id);
        if l_pr.status <> 'APPROVED' then
            fail('A purchase order can only be created from an APPROVED request. Current status: '
                 || l_pr.status || '.');
        end if;

        begin
            select is_active into l_active from p2s_suppliers where supplier_id = p_supplier_id;
        exception
            when no_data_found then
                fail('Please select a valid supplier.');
        end;
        if l_active <> 'Y' then
            fail('The selected supplier is inactive.');
        end if;

        l_po_number := next_doc_no('PO');

        insert into p2s_po_headers (po_number, pr_id, supplier_id, expected_date)
        values (l_po_number, p_pr_id, p_supplier_id, p_expected_date)
        returning po_id into l_po_id;

        insert into p2s_po_lines (po_id, line_no, pr_line_id, item_id, qty_ordered, unit_price)
        select l_po_id, l.line_no, l.pr_line_id, l.item_id, l.quantity, l.est_unit_price
          from p2s_pr_lines l
         where l.pr_id = p_pr_id;

        update p2s_po_headers h
           set total_amount = (select coalesce(sum(pl.line_amount), 0)
                                 from p2s_po_lines pl
                                where pl.po_id = h.po_id)
         where h.po_id = l_po_id;

        update p2s_pr_headers set status = 'CONVERTED' where pr_id = p_pr_id;

        return l_po_id;
    exception
        when others then
            p2s_err.log_error(c_module || 'CREATE_PO_FROM_PR',
                'pr=' || p_pr_id || ' supplier=' || p_supplier_id);
            raise;
    end create_po_from_pr;

    function create_grn (
        p_po_id in number,
        p_notes in varchar2 default null) return number
    is
        l_po_status  p2s_po_headers.status%type;
        l_pr_id      number;
        l_wh_id      number;
        l_grn_id     number;
        l_grn_number p2s_grn_headers.grn_number%type;
        l_user_id    number;
    begin
        p2s_app.require_role('STOREKEEPER');
        l_user_id := p2s_app.current_user_id;

        begin
            select status, pr_id
              into l_po_status, l_pr_id
              from p2s_po_headers
             where po_id = p_po_id
               for update;
        exception
            when no_data_found then
                fail('Purchase order not found.');
        end;

        if l_po_status not in ('OPEN', 'PARTIAL') then
            fail('Goods can only be received for OPEN or PARTIAL orders. Current status: ' || l_po_status || '.');
        end if;

        select warehouse_id into l_wh_id from p2s_pr_headers where pr_id = l_pr_id;

        l_grn_number := next_doc_no('GRN');

        insert into p2s_grn_headers (grn_number, po_id, warehouse_id, received_by_id, notes)
        values (l_grn_number, p_po_id, l_wh_id, l_user_id, p_notes)
        returning grn_id into l_grn_id;

        return l_grn_id;
    exception
        when others then
            p2s_err.log_error(c_module || 'CREATE_GRN', 'po=' || p_po_id);
            raise;
    end create_grn;

    procedure add_grn_line (
        p_grn_id     in number,
        p_po_line_id in number,
        p_qty        in number)
    is
        l_grn_status p2s_grn_headers.status%type;
        l_grn_po_id  number;
        l_line_po_id number;
        l_ordered    number;
        l_received   number;
    begin
        p2s_app.require_role('STOREKEEPER');

        begin
            select status, po_id
              into l_grn_status, l_grn_po_id
              from p2s_grn_headers
             where grn_id = p_grn_id
               for update;
        exception
            when no_data_found then
                fail('Goods receipt not found.');
        end;

        if l_grn_status <> 'DRAFT' then
            fail('Lines can only be added to a DRAFT receipt.');
        end if;

        begin
            select po_id, qty_ordered, qty_received
              into l_line_po_id, l_ordered, l_received
              from p2s_po_lines
             where po_line_id = p_po_line_id;
        exception
            when no_data_found then
                fail('Purchase order line not found.');
        end;

        if l_line_po_id <> l_grn_po_id then
            fail('This line does not belong to the purchase order of this receipt.');
        end if;
        if p_qty is null or p_qty <= 0 then
            fail('Received quantity must be greater than zero.');
        end if;
        if p_qty > l_ordered - l_received then
            fail('Quantity exceeds the remaining quantity. Remaining: ' || (l_ordered - l_received) || '.');
        end if;

        insert into p2s_grn_lines (grn_id, po_line_id, qty_received)
        values (p_grn_id, p_po_line_id, p_qty);
    exception
        when others then
            p2s_err.log_error(c_module || 'ADD_GRN_LINE',
                'grn=' || p_grn_id || ' po_line=' || p_po_line_id || ' qty=' || p_qty);
            raise;
    end add_grn_line;

    procedure post_grn (p_grn_id in number) is
        l_grn       p2s_grn_headers%rowtype;
        l_po_status p2s_po_headers.status%type;
        l_lines     number;
        l_ordered   number;
        l_received  number;
        l_open      number;
    begin
        p2s_app.require_role('STOREKEEPER');

        begin
            select * into l_grn from p2s_grn_headers where grn_id = p_grn_id for update;
        exception
            when no_data_found then
                fail('Goods receipt not found.');
        end;

        if l_grn.status <> 'DRAFT' then
            fail('This receipt is already posted.');
        end if;

        select status into l_po_status from p2s_po_headers where po_id = l_grn.po_id for update;
        if l_po_status not in ('OPEN', 'PARTIAL') then
            fail('The purchase order is ' || l_po_status || ' and cannot receive goods.');
        end if;

        select count(*) into l_lines from p2s_grn_lines where grn_id = p_grn_id;
        if l_lines = 0 then
            fail('Add at least one line before posting the receipt.');
        end if;

        for r in (select gl.po_line_id, gl.qty_received, pl.item_id, pl.line_no
                    from p2s_grn_lines gl
                    join p2s_po_lines  pl on pl.po_line_id = gl.po_line_id
                   where gl.grn_id = p_grn_id
                   order by pl.line_no)
        loop
            select qty_ordered, qty_received
              into l_ordered, l_received
              from p2s_po_lines
             where po_line_id = r.po_line_id
               for update;

            if r.qty_received > l_ordered - l_received then
                fail('PO line ' || r.line_no || ': quantity exceeds the remaining quantity ('
                     || (l_ordered - l_received) || ').');
            end if;

            update p2s_po_lines
               set qty_received = qty_received + r.qty_received
             where po_line_id   = r.po_line_id;

            p2s_stock.post_movement(
                p_movement_type => 'RECEIPT',
                p_warehouse_id  => l_grn.warehouse_id,
                p_item_id       => r.item_id,
                p_quantity      => r.qty_received,
                p_ref_type      => 'GRN',
                p_ref_id        => p_grn_id,
                p_reason        => 'Goods receipt ' || l_grn.grn_number);
        end loop;

        update p2s_grn_headers
           set status    = 'POSTED',
               posted_on = systimestamp
         where grn_id    = p_grn_id;

        select count(*)
          into l_open
          from p2s_po_lines
         where po_id = l_grn.po_id
           and qty_received < qty_ordered;

        update p2s_po_headers
           set status = case when l_open = 0 then 'RECEIVED' else 'PARTIAL' end
         where po_id  = l_grn.po_id;
    exception
        when others then
            p2s_err.log_error(c_module || 'POST_GRN', 'grn=' || p_grn_id);
            raise;
    end post_grn;

end p2s_purchase;
/

select object_name, object_type, status
  from user_objects
 where object_name = 'P2S_PURCHASE';
