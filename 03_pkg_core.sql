-- P2S Purchase-to-Stock
-- P2S_ERR (error handling) and P2S_APP (users and roles)

create or replace package p2s_err as

    c_business_error constant pls_integer := -20001;

    procedure raise_error (p_message in varchar2);

    procedure log_error (
        p_module  in varchar2,
        p_context in varchar2 default null);

    function constraint_message (p_constraint_name in varchar2) return varchar2;

    function apex_error_handler (p_error in apex_error.t_error)
        return apex_error.t_error_result;

end p2s_err;
/

create or replace package body p2s_err as

    function current_app_user return varchar2 is
    begin
        return coalesce(sys_context('APEX$SESSION', 'APP_USER'), user);
    end current_app_user;

    procedure raise_error (p_message in varchar2) is
    begin
        raise_application_error(c_business_error, p_message);
    end raise_error;

    procedure write_log (
        p_module    in varchar2,
        p_code      in number,
        p_message   in varchar2,
        p_backtrace in varchar2,
        p_context   in varchar2)
    is
        pragma autonomous_transaction;
        l_app_user varchar2(255) := substr(current_app_user, 1, 255);
    begin
        insert into p2s_error_log
            (app_user, module_name, error_code, error_message, error_backtrace, context_info)
        values
            (l_app_user,
             substr(p_module,    1, 200),
             p_code,
             substr(p_message,   1, 4000),
             substr(p_backtrace, 1, 4000),
             substr(p_context,   1, 4000));
        commit;
    exception
        when others then
            rollback;
    end write_log;

    procedure log_error (
        p_module  in varchar2,
        p_context in varchar2 default null)
    is
        l_code number := sqlcode;
    begin
        if l_code between -20999 and -20000 then
            return;
        end if;
        write_log(p_module,
                  l_code,
                  dbms_utility.format_error_stack,
                  dbms_utility.format_error_backtrace,
                  p_context);
    end log_error;

    function constraint_message (p_constraint_name in varchar2) return varchar2 is
    begin
        return case upper(p_constraint_name)
            when 'P2S_USERS_UK'        then 'This username already exists.'
            when 'P2S_USERS_UPPER_CK'  then 'Username must be in upper case.'
            when 'P2S_SUPPLIERS_UK'    then 'This supplier code already exists.'
            when 'P2S_WAREHOUSES_UK'   then 'This warehouse code already exists.'
            when 'P2S_ITEMS_UK'        then 'This item code already exists.'
            when 'P2S_ITEMS_PRICE_CK'  then 'Standard price cannot be negative.'
            when 'P2S_ITEMS_REORD_CK'  then 'Reorder level cannot be negative.'
            when 'P2S_APPR_RULES_UK'   then 'An approval rule already exists for this level.'
            when 'P2S_APPR_RULES_THR_CK' then 'Threshold amount cannot be negative.'
            when 'P2S_PR_DATES_CK'     then 'Needed-by date cannot be before the request date.'
            when 'P2S_PRL_ITEM_UK'     then 'This item is already on the request. Change its quantity instead.'
            when 'P2S_PRL_QTY_CK'      then 'Quantity must be greater than zero.'
            when 'P2S_PRL_PRICE_CK'    then 'Price cannot be negative.'
            when 'P2S_PRA_REJECT_CK'   then 'A reason is required when rejecting.'
            when 'P2S_PO_DATES_CK'     then 'Expected date cannot be before the order date.'
            when 'P2S_POL_RECV_CK'     then 'Received quantity cannot exceed the ordered quantity.'
            when 'P2S_GRNL_QTY_CK'     then 'Received quantity must be greater than zero.'
            when 'P2S_GRNL_POL_UK'     then 'This PO line is already on the receipt.'
            when 'P2S_STB_QTY_CK'      then 'Not enough stock. The balance cannot go below zero.'
            when 'P2S_STM_BAL_CK'      then 'Not enough stock. The balance cannot go below zero.'
            else null
        end;
    end constraint_message;

    function apex_error_handler (p_error in apex_error.t_error)
        return apex_error.t_error_result
    is
        l_result     apex_error.t_error_result;
        l_constraint varchar2(255);
        l_friendly   varchar2(4000);
    begin
        l_result := apex_error.init_error_result(p_error => p_error);

        if p_error.is_internal_error then
            if not p_error.is_common_runtime_error then
                write_log('APEX',
                          p_error.ora_sqlcode,
                          p_error.message || ' | ' || p_error.ora_sqlerrm,
                          p_error.error_backtrace,
                          'apex_error_code=' || p_error.apex_error_code);
                l_result.message         := 'An unexpected error occurred. It has been logged for the administrator.';
                l_result.additional_info := null;
            end if;
        else
            if l_result.display_location = apex_error.c_on_error_page then
                l_result.display_location := apex_error.c_inline_in_notification;
            end if;

            if p_error.ora_sqlcode in (-1, -2290, -2291, -2292) then
                l_constraint := apex_error.extract_constraint_name(p_error => p_error);
                l_friendly   := constraint_message(l_constraint);
                if l_friendly is null then
                    l_friendly := case p_error.ora_sqlcode
                        when -2292 then 'This record is used by other records and cannot be deleted.'
                        when -2291 then 'The selected related record does not exist.'
                        when -1    then 'This record already exists.'
                    end;
                end if;
                if l_friendly is not null then
                    l_result.message := l_friendly;
                end if;

            elsif p_error.ora_sqlcode between -20999 and -20000 then
                l_result.message := apex_error.get_first_ora_error_text(p_error => p_error);

            elsif p_error.ora_sqlcode is not null then
                write_log('APEX',
                          p_error.ora_sqlcode,
                          p_error.ora_sqlerrm,
                          p_error.error_backtrace,
                          null);
                l_result.message := 'An unexpected database error occurred. It has been logged for the administrator.';
            end if;

            if l_result.page_item_name is null and l_result.column_alias is null then
                apex_error.auto_set_associated_item(
                    p_error        => p_error,
                    p_error_result => l_result);
            end if;
        end if;

        return l_result;
    end apex_error_handler;

end p2s_err;
/

create or replace package p2s_app as

    function current_username return varchar2;

    function current_user_id return number;

    function user_role return varchar2;

    function has_role (p_role in varchar2) return boolean;

    procedure require_role (p_roles in varchar2);

    procedure set_test_user (p_username in varchar2);
    procedure clear_test_user;

end p2s_app;
/

create or replace package body p2s_app as

    g_test_user varchar2(255);

    function real_username return varchar2 is
    begin
        return upper(coalesce(sys_context('APEX$SESSION', 'APP_USER'), user));
    end real_username;

    function current_username return varchar2 is
    begin
        return coalesce(g_test_user, real_username);
    end current_username;

    function find_role (p_username in varchar2) return varchar2 is
        l_role p2s_users.role_code%type;
    begin
        select role_code
          into l_role
          from p2s_users
         where username  = p_username
           and is_active = 'Y';
        return l_role;
    exception
        when no_data_found then
            return null;
    end find_role;

    function current_user_id return number is
        l_username varchar2(255) := current_username;
        l_id       number;
    begin
        select user_id
          into l_id
          from p2s_users
         where username  = l_username
           and is_active = 'Y';
        return l_id;
    exception
        when no_data_found then
            p2s_err.raise_error('User ' || l_username || ' is not registered as an active P2S user.');
            return null;
    end current_user_id;

    function user_role return varchar2 is
        l_role p2s_users.role_code%type := find_role(current_username);
    begin
        if l_role is null then
            p2s_err.raise_error('User ' || current_username || ' is not registered as an active P2S user.');
        end if;
        return l_role;
    end user_role;

    function has_role (p_role in varchar2) return boolean is
        l_role p2s_users.role_code%type := find_role(current_username);
    begin
        return l_role is not null
           and (l_role = 'ADMIN' or l_role = upper(p_role));
    end has_role;

    procedure require_role (p_roles in varchar2) is
        l_role p2s_users.role_code%type := user_role;
    begin
        if l_role <> 'ADMIN'
           and instr(',' || upper(replace(p_roles, ' ')) || ',', ',' || l_role || ',') = 0
        then
            p2s_err.raise_error('You do not have permission for this action. Required role: ' || p_roles || '.');
        end if;
    end require_role;

    procedure set_test_user (p_username in varchar2) is
    begin
        if nvl(find_role(real_username), 'X') <> 'ADMIN' then
            p2s_err.raise_error('Only an ADMIN can switch test users.');
        end if;
        if find_role(upper(p_username)) is null then
            p2s_err.raise_error('Test user ' || p_username || ' not found or inactive.');
        end if;
        g_test_user := upper(p_username);
    end set_test_user;

    procedure clear_test_user is
    begin
        g_test_user := null;
    end clear_test_user;

end p2s_app;
/

select object_name, object_type, status
  from user_objects
 where object_name in ('P2S_ERR', 'P2S_APP')
 order by object_name, object_type;
