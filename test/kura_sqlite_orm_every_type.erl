-module(kura_sqlite_orm_every_type).
-moduledoc "One field of every kura type SQLite stores.".
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"every_type".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = int, type = integer},
        #kura_field{name = big, type = bigint},
        #kura_field{name = small, type = smallint},
        #kura_field{name = ratio, type = float},
        #kura_field{name = amount, type = decimal},
        #kura_field{name = name, type = string},
        #kura_field{name = body, type = text},
        #kura_field{name = bytes, type = binary},
        #kura_field{name = active, type = boolean},
        #kura_field{name = day, type = date},
        #kura_field{name = wakes, type = time},
        #kura_field{name = at, type = utc_datetime},
        #kura_field{name = local_at, type = naive_datetime},
        #kura_field{name = ref, type = uuid},
        #kura_field{name = doc, type = jsonb},
        #kura_field{name = role, type = {enum, [admin, member]}},
        #kura_field{name = token, type = {encrypted, string}},
        #kura_field{name = label, type = {custom, kura_sqlite_text_type}},
        #kura_field{name = raw, type = {custom, kura_sqlite_bytes_type}}
    ].
