-module(kura_sqlite_orm_author).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, embeds/0, indexes/0]).

table() -> ~"authors".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = name, type = string, nullable = false},
        #kura_field{name = email, type = string, column = ~"email_address"},
        #kura_field{name = age, type = integer},
        #kura_field{name = active, type = boolean, default = true},
        #kura_field{name = role, type = {enum, [admin, member]}},
        #kura_field{name = score, type = float},
        #kura_field{name = settings, type = jsonb},
        #kura_field{name = born, type = date},
        #kura_field{name = balance, type = decimal},
        #kura_field{name = ref, type = uuid},
        #kura_field{name = wakes, type = time},
        #kura_field{name = lock_version, type = integer, default = 1},
        #kura_field{name = inserted_at, type = utc_datetime},
        #kura_field{name = updated_at, type = utc_datetime}
    ].

associations() ->
    [
        #kura_assoc{
            name = posts,
            type = has_many,
            schema = kura_sqlite_orm_post,
            foreign_key = author_id
        }
    ].

embeds() ->
    [#kura_embed{name = address, type = embeds_one, schema = kura_sqlite_orm_address}].

indexes() ->
    [{[email], #{unique => true}}].
