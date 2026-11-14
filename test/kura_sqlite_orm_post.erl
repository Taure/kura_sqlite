-module(kura_sqlite_orm_post).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, timestamps/0]).

table() -> ~"posts".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = title, type = string, nullable = false},
        #kura_field{name = body, type = text},
        #kura_field{name = views, type = integer, default = 0},
        #kura_field{name = author_id, type = integer},
        #kura_field{name = created_at, type = utc_datetime},
        #kura_field{name = modified_at, type = utc_datetime, column = ~"changed_at"}
    ].

timestamps() -> [{created_at, utc_datetime}, {modified_at, utc_datetime}].

associations() ->
    [
        #kura_assoc{
            name = author,
            type = belongs_to,
            schema = kura_sqlite_orm_author,
            foreign_key = author_id
        },
        #kura_assoc{
            name = tags,
            type = many_to_many,
            schema = kura_sqlite_orm_tag,
            join_through = ~"posts_tags",
            join_keys = {post_id, tag_id}
        }
    ].
