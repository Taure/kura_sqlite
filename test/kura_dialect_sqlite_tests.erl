-module(kura_dialect_sqlite_tests).
-include_lib("eunit/include/eunit.hrl").

%%----------------------------------------------------------------------
%% swap_placeholders/1
%%----------------------------------------------------------------------

swap_replaces_dollar_with_question_mark_test() ->
    ?assertEqual(<<"SELECT ?1, ?2">>, kura_dialect_sqlite:swap_placeholders(<<"SELECT $1, $2">>)).

swap_handles_iodata_input_test() ->
    ?assertEqual(
        <<"WHERE ?1 = ?2">>, kura_dialect_sqlite:swap_placeholders([~"WHERE ", ~"$1 = $2"])
    ).

swap_no_placeholders_unchanged_test() ->
    ?assertEqual(<<"SELECT 1">>, kura_dialect_sqlite:swap_placeholders(<<"SELECT 1">>)).

swap_double_digit_placeholder_test() ->
    ?assertEqual(
        <<"SELECT ?12, ?34">>, kura_dialect_sqlite:swap_placeholders(<<"SELECT $12, $34">>)
    ).

%%----------------------------------------------------------------------
%% column_type/1: SQLite type mapping
%%----------------------------------------------------------------------

column_type_basics_test_() ->
    [
        ?_assertEqual(~"INTEGER", kura_dialect_sqlite:column_type(id)),
        ?_assertEqual(~"INTEGER", kura_dialect_sqlite:column_type(integer)),
        ?_assertEqual(~"INTEGER", kura_dialect_sqlite:column_type(boolean)),
        ?_assertEqual(~"REAL", kura_dialect_sqlite:column_type(float)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type(string)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type(text)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type(uuid)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type(jsonb)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type(utc_datetime)),
        ?_assertEqual(~"BLOB", kura_dialect_sqlite:column_type(binary)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type({enum, [a, b]})),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type({array, integer}))
    ].

%%----------------------------------------------------------------------
%% format_default/1: SQLite-flavoured default literals
%%----------------------------------------------------------------------

format_default_test_() ->
    [
        ?_assertEqual(~"42", kura_dialect_sqlite:format_default(42)),
        ?_assertEqual(~"1", kura_dialect_sqlite:format_default(true)),
        ?_assertEqual(~"0", kura_dialect_sqlite:format_default(false)),
        ?_assertEqual(<<"'hello'">>, kura_dialect_sqlite:format_default(<<"hello">>)),
        ?_assertEqual(<<"'{\"a\":1}'">>, kura_dialect_sqlite:format_default(#{a => 1}))
    ].

%%----------------------------------------------------------------------
%% Behaviour declaration
%%----------------------------------------------------------------------

declares_kura_dialect_behaviour_test() ->
    Attrs = kura_dialect_sqlite:module_info(attributes),
    Behaviours = lists:append([V || {behaviour, V} <- Attrs] ++ [V || {behavior, V} <- Attrs]),
    ?assert(lists:member(kura_dialect, Behaviours)).
