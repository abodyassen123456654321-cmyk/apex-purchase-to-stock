-- P2S Purchase-to-Stock
-- End-to-end business flow test (run in SQL Commands)

declare
    l_wh        number;
    l_sup       number;
    l_laptop    number;
    l_dock      number;
    l_pr        number;
    l_pr2       number;
    l_po        number;
    l_grn       number;
    l_grn2      number;
    l_pol_lap   number;
    l_pol_dock  number;
    l_lap_start  number;
    l_dock_start number;
    l_passed    pls_integer := 0;
    l_failed    pls_integer := 0;

    procedure ok (p_text in varchar2) is
    begin
        l_passed := l_passed + 1;
        dbms_output.put_line('PASS  ' || p_text);
    end;

    procedure ko (p_text in varchar2) is
    begin
        l_failed := l_failed + 1;
        dbms_output.put_line('FAIL  ' || p_text);
    end;

    procedure expect_error (p_code in number, p_msg in varchar2, p_text in varchar2) is
    begin
        if p_code = -20001 then
            ok(p_text || ' -> ' || p_msg);
        else
            ko(p_text || ' -> UNEXPECTED ' || p_msg);
        end if;
    end;

    procedure check_status (p_table in varchar2, p_id in number, p_expected in varchar2) is
        l_actual varchar2(20);
    begin
        if p_table = 'PR' then
            select status into l_actual from p2s_pr_headers where pr_id = p_id;
        elsif p_table = 'PO' then
            select status into l_actual from p2s_po_headers where po_id = p_id;
        else
            select status into l_actual from p2s_grn_headers where grn_id = p_id;
        end if;
        if l_actual = p_expected then
            ok(p_table || ' status = ' || p_expected);
        else
            ko(p_table || ' status expected ' || p_expected || ' but was ' || l_actual);
        end if;
    end;
begin
    select warehouse_id into l_wh     from p2s_warehouses where warehouse_code = 'WH-MAIN';
    select supplier_id  into l_sup    from p2s_suppliers  where supplier_code  = 'SUP-002';
    select item_id      into l_laptop from p2s_items      where item_code      = 'ITM-2001';
    select item_id      into l_dock   from p2s_items      where item_code      = 'ITM-2002';

    l_lap_start  := p2s_stock.get_on_hand(l_wh, l_laptop);
    l_dock_start := p2s_stock.get_on_hand(l_wh, l_dock);

    p2s_app.set_test_user('SARA.REQ');
    l_pr := p2s_purchase.create_pr(l_wh, trunc(sysdate) + 14, 'Laptops for two new hires');
    p2s_purchase.add_pr_line(l_pr, l_laptop, 2);
    p2s_purchase.add_pr_line(l_pr, l_dock,   2);
    p2s_purchase.submit_pr(l_pr);
    check_status('PR', l_pr, 'SUBMITTED');

    p2s_app.set_test_user('LINA.FIN');
    begin
        p2s_purchase.approve_pr(l_pr);
        ko('Finance approved before Manager');
    exception when others then
        expect_error(sqlcode, sqlerrm, 'Level order enforced');
    end;

    p2s_app.set_test_user('OMAR.MGR');
    p2s_purchase.approve_pr(l_pr, 'Approved for new hires');
    check_status('PR', l_pr, 'SUBMITTED');

    p2s_app.set_test_user('LINA.FIN');
    p2s_purchase.approve_pr(l_pr, 'Budget available');
    check_status('PR', l_pr, 'APPROVED');

    l_po := p2s_purchase.create_po_from_pr(l_pr, l_sup, trunc(sysdate) + 7);
    check_status('PR', l_pr, 'CONVERTED');
    check_status('PO', l_po, 'OPEN');

    select po_line_id into l_pol_lap  from p2s_po_lines where po_id = l_po and item_id = l_laptop;
    select po_line_id into l_pol_dock from p2s_po_lines where po_id = l_po and item_id = l_dock;

    begin
        l_grn := p2s_purchase.create_grn(l_po);
        ko('Finance created a goods receipt');
    exception when others then
        expect_error(sqlcode, sqlerrm, 'Role check enforced');
    end;

    p2s_app.set_test_user('KHALED.STORE');
    l_grn := p2s_purchase.create_grn(l_po, 'First delivery');
    p2s_purchase.add_grn_line(l_grn, l_pol_lap,  1);
    p2s_purchase.add_grn_line(l_grn, l_pol_dock, 2);
    p2s_purchase.post_grn(l_grn);
    check_status('GRN', l_grn, 'POSTED');
    check_status('PO',  l_po,  'PARTIAL');

    l_grn2 := p2s_purchase.create_grn(l_po, 'Second delivery');
    begin
        p2s_purchase.add_grn_line(l_grn2, l_pol_lap, 5);
        ko('Over-receipt was accepted');
    exception when others then
        expect_error(sqlcode, sqlerrm, 'Over-receipt blocked');
    end;

    p2s_purchase.add_grn_line(l_grn2, l_pol_lap, 1);
    p2s_purchase.post_grn(l_grn2);
    check_status('PO', l_po, 'RECEIVED');

    if p2s_stock.get_on_hand(l_wh, l_laptop) = l_lap_start  + 2
       and p2s_stock.get_on_hand(l_wh, l_dock) = l_dock_start + 2 then
        ok('Stock on hand increased correctly (+2 laptops, +2 docks)');
    else
        ko('Stock on hand is wrong');
    end if;

    begin
        p2s_stock.adjust_stock(l_wh, l_laptop, -(p2s_stock.get_on_hand(l_wh, l_laptop) + 1), 'Test negative stock');
        ko('Negative stock was accepted');
    exception when others then
        expect_error(sqlcode, sqlerrm, 'Negative stock blocked');
    end;

    p2s_app.set_test_user('SARA.REQ');
    l_pr2 := p2s_purchase.create_pr(l_wh, null, 'Spare laptop');
    p2s_purchase.add_pr_line(l_pr2, l_laptop, 1);
    p2s_purchase.submit_pr(l_pr2);
    begin
        p2s_purchase.approve_pr(l_pr2);
        ko('Requester approved own request');
    exception when others then
        expect_error(sqlcode, sqlerrm, 'Self-approval blocked');
    end;

    p2s_app.set_test_user('OMAR.MGR');
    begin
        p2s_purchase.reject_pr(l_pr2, null);
        ko('Rejection without reason accepted');
    exception when others then
        expect_error(sqlcode, sqlerrm, 'Rejection reason required');
    end;
    p2s_purchase.reject_pr(l_pr2, 'Not needed this month');
    check_status('PR', l_pr2, 'REJECTED');

    p2s_app.clear_test_user;
    commit;

    dbms_output.put_line('------------------------------------------');
    dbms_output.put_line('RESULT: ' || l_passed || ' passed, ' || l_failed || ' failed');
exception
    when others then
        p2s_app.clear_test_user;
        rollback;
        dbms_output.put_line('UNEXPECTED ERROR: ' || sqlerrm);
        dbms_output.put_line(dbms_utility.format_error_backtrace);
end;
