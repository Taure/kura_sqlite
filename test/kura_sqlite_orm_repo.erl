-module(kura_sqlite_orm_repo).
-behaviour(kura_repo).

-export([otp_app/0]).

otp_app() -> kura_sqlite.
