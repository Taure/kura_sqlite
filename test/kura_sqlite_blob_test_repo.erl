-module(kura_sqlite_blob_test_repo).
-behaviour(kura_repo).

-export([otp_app/0]).

otp_app() -> kura_sqlite_blob_test_app.
