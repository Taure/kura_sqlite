-module(kura_sqlite_e2e_test_repo).
-behaviour(kura_repo).

-export([otp_app/0]).

otp_app() -> kura_sqlite_e2e_test_app.
