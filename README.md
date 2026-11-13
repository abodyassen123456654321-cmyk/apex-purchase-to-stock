# Purchase-to-Stock (P2S)

An Oracle APEX application that manages the full purchasing cycle, from purchase request to stock on hand.

**Stack:** Oracle APEX 26.1 · Oracle Database · SQL · PL/SQL

## Business flow

```
Purchase Request → Approvals (by amount) → Purchase Order → Goods Receipt → Stock
```

| Step | Who | What happens |
|---|---|---|
| Purchase Request | Requester | Creates a request with lines and submits it |
| Approval | Manager / Finance | Approves level by level, based on the request total |
| Purchase Order | Finance | Converts the approved request to a PO for a supplier |
| Goods Receipt | Storekeeper | Receives full or partial quantities and posts the receipt |
| Inventory | System | Updates stock balance and writes a movement record |

## Business rules

- Only DRAFT requests can be edited, and only by their requester
- Approval levels come from a configurable approval matrix (e.g. Finance approval above 1,000)
- Levels are approved in order, each by its own role
- Users cannot approve or reject their own requests
- A rejection always requires a reason
- Received quantity can never exceed the ordered quantity
- Stock can never go below zero, even with concurrent users (row locking)
- Every stock change is recorded in a movement ledger

## Technical design

- **Data integrity in the database:** primary, foreign, unique and check constraints
- **Business logic in PL/SQL packages:** APEX pages only call the packages
  - `P2S_PURCHASE`: requests, approvals, purchase orders, goods receipts
  - `P2S_STOCK`: the only code that changes stock
  - `P2S_APP`: current user, roles and permission checks
  - `P2S_ERR`: error logging and APEX error handling function
- **Error handling:** business errors return clear messages; unexpected errors are logged
- **Audit columns** on every table (created / updated by and on)
- **Automated test** for the full flow, including negative cases

## Data model

| Area | Tables |
|---|---|
| Master data | `P2S_USERS`, `P2S_SUPPLIERS`, `P2S_WAREHOUSES`, `P2S_ITEMS`, `P2S_APPROVAL_RULES` |
| Purchasing | `P2S_PR_HEADERS`, `P2S_PR_LINES`, `P2S_PR_APPROVALS`, `P2S_PO_HEADERS`, `P2S_PO_LINES` |
| Receiving | `P2S_GRN_HEADERS`, `P2S_GRN_LINES` |
| Inventory | `P2S_STOCK_BALANCES`, `P2S_STOCK_MOVEMENTS` |
| Logging | `P2S_ERROR_LOG` |

## Installation

Run the scripts in order (SQL Workshop > SQL Scripts):

1. `01_tables.sql`
2. `02_seed_data.sql`
3. `03_pkg_core.sql`
4. `04_pkg_stock.sql`
5. `05_pkg_purchase.sql`

Then run `06_test_flow.sql` in SQL Commands. Expected result: all tests passed, 0 failed.

`00_drop_all.sql` removes all P2S objects (development only).

## Status

- [x] Data model
- [x] Business logic packages
- [x] Automated tests
- [ ] APEX pages
- [ ] Dashboard and reports
- [ ] Live demo

All data in this project is fictional.
