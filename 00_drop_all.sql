-- =====================================================================
--  P2S : Purchase-to-Stock
--  Script : 00_drop_all.sql
--  Purpose: Remove ALL P2S objects so 01 and 02 can be re-run cleanly.
--  WARNING: deletes every P2S_ table and its data. Use only in DEV.
-- =====================================================================

begin
    for t in (select table_name from user_tables
               where table_name like 'P2S\_%' escape '\') loop
        execute immediate 'drop table ' || t.table_name || ' cascade constraints purge';
    end loop;

    for s in (select sequence_name from user_sequences
               where sequence_name like 'P2S\_%' escape '\') loop
        execute immediate 'drop sequence ' || s.sequence_name;
    end loop;
end;
/
