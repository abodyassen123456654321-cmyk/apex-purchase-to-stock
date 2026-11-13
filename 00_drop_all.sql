-- P2S Purchase-to-Stock
-- Drop all P2S objects (DEV only)

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
