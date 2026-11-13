-- =====================================================================
--  P2S : Purchase-to-Stock
--  Script : 02_seed_data.sql
--  Purpose: Demo master data (all fictional).
--  Run after 01_tables.sql
-- =====================================================================

-- Demo users (one per role)
insert into p2s_users (username, full_name, email, role_code) values ('SARA.REQ',     'Sara Requester',    'sara@demo.local',   'REQUESTER');
insert into p2s_users (username, full_name, email, role_code) values ('OMAR.MGR',     'Omar Manager',      'omar@demo.local',   'MANAGER');
insert into p2s_users (username, full_name, email, role_code) values ('LINA.FIN',     'Lina Finance',      'lina@demo.local',   'FINANCE');
insert into p2s_users (username, full_name, email, role_code) values ('KHALED.STORE', 'Khaled Storekeeper','khaled@demo.local', 'STOREKEEPER');

-- The developer running this script becomes ADMIN (your APEX username)
insert into p2s_users (username, full_name, role_code)
select upper(coalesce(sys_context('APEX$SESSION','APP_USER'), user)), 'Application Admin', 'ADMIN'
  from dual
 where not exists (
        select 1 from p2s_users
         where username = upper(coalesce(sys_context('APEX$SESSION','APP_USER'), user)));

-- Warehouses
insert into p2s_warehouses (warehouse_code, warehouse_name) values ('WH-MAIN',  'Main Warehouse');
insert into p2s_warehouses (warehouse_code, warehouse_name) values ('WH-NORTH', 'North Branch Warehouse');

-- Suppliers
insert into p2s_suppliers (supplier_code, supplier_name, email, phone) values ('SUP-001', 'Alpha Office Supplies', 'sales@alpha.demo',  '+000 100 0001');
insert into p2s_suppliers (supplier_code, supplier_name, email, phone) values ('SUP-002', 'Beta IT Equipment',     'orders@beta.demo',  '+000 100 0002');
insert into p2s_suppliers (supplier_code, supplier_name, email, phone) values ('SUP-003', 'Gamma Cleaning Co.',    'info@gamma.demo',   '+000 100 0003');

-- Items
insert into p2s_items (item_code, item_name, uom, standard_price, reorder_level) values ('ITM-1001', 'A4 Paper (500 sheets)',  'BOX',   4.50, 50);
insert into p2s_items (item_code, item_name, uom, standard_price, reorder_level) values ('ITM-1002', 'Blue Ballpoint Pen',     'PCS',   0.30, 200);
insert into p2s_items (item_code, item_name, uom, standard_price, reorder_level) values ('ITM-1003', 'Stapler',                'PCS',   6.00, 10);
insert into p2s_items (item_code, item_name, uom, standard_price, reorder_level) values ('ITM-2001', 'Laptop 14"',             'PCS', 650.00, 2);
insert into p2s_items (item_code, item_name, uom, standard_price, reorder_level) values ('ITM-2002', 'USB-C Docking Station',  'PCS',  95.00, 3);
insert into p2s_items (item_code, item_name, uom, standard_price, reorder_level) values ('ITM-2003', '24" Monitor',            'PCS', 140.00, 2);
insert into p2s_items (item_code, item_name, uom, standard_price, reorder_level) values ('ITM-3001', 'Floor Cleaner 5L',       'BTL',   7.25, 20);
insert into p2s_items (item_code, item_name, uom, standard_price, reorder_level) values ('ITM-3002', 'Paper Towels (6 rolls)', 'PACK',  3.80, 30);

-- Approval matrix
--   Level 1: Manager approves every PR (total > 0)
--   Level 2: Finance also approves when total > 1000
insert into p2s_approval_rules (approval_level, approver_role, threshold_amount) values (1, 'MANAGER', 0);
insert into p2s_approval_rules (approval_level, approver_role, threshold_amount) values (2, 'FINANCE', 1000);

commit;

-- Check: expected 5 users, 2 warehouses, 3 suppliers, 8 items, 2 rules
select 'USERS' tbl, count(*) cnt from p2s_users union all
select 'WAREHOUSES',      count(*) from p2s_warehouses union all
select 'SUPPLIERS',       count(*) from p2s_suppliers union all
select 'ITEMS',           count(*) from p2s_items union all
select 'APPROVAL_RULES',  count(*) from p2s_approval_rules;
