-module(seb_session).
-author('Dmitry Krapivnoy').
-include_lib("n2o/include/wf.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-compile(export_all).

finish(State,Ctx) -> {ok,State,Ctx}.
init(State,Ctx) -> case wf:config(n2o,auto_session) of
                        disabled -> {ok,State,Ctx};
                        _ -> n2o_session:ensure_sid(State,Ctx,[]) end.

ensure_sid(State, Ctx, []) -> ensure_sid(State, Ctx, site);
ensure_sid(State, Ctx, From) ->
    SessionId   = wf:cookie_req(session_cookie_name(From), Ctx#cx.req),
    wf:info(?MODULE,"Ensure SID ~p-sid=~p~n",[From,SessionId]),
    session_sid(State, Ctx, SessionId, From).

session_sid(SID, Source) -> session_sid([], ?CTX, SID, Source).
session_sid(State, Ctx, SessionId, From) ->
    wf:info(?MODULE,"Session Init ~p: ~p",[From,SessionId]),
    Lookup = lookup_ets({SessionId,<<"auth">>}),
    NewTill = till(calendar:local_time(), ttl()),
    SessionCookie = case Lookup of
        undefined ->
            CookieValue = case SessionId of
                undefined -> case wf:qc(wf:config(n2o,transfer_session,<<"csid">>),Ctx) of
                    undefined -> new_cookie_value(From);
                    Csid -> new_cookie_value(Csid, From) end;
                _ -> new_cookie_value(SessionId,From) end,
            Cookie = {{CookieValue,<<"auth">>},<<"/">>,os:timestamp(),NewTill,new},
            ets:insert(cookies,Cookie),
            wf:info(?MODULE,"Auth Cookie New: ~p~n",[Cookie]),
            Cookie;
        {{Session,Key},Path,Issued,Till,Status} ->
            case expired(Issued,Till) of
                false ->
                    Cookie = {{Session,Key},Path,Issued,Till,Status},
                    wf:info(?MODULE,"Auth Cookie Same: ~p",[Cookie]),
                    Cookie;
                true ->
                    Cookie = {{new_cookie_value(From),<<"auth">>},<<"/">>,os:timestamp(),NewTill,new},
                    clear(Session),
                    ets:insert(cookies,Cookie),
                    wf:info(?MODULE,"Auth Cookie Expired in Session ~p~n",[Session]),
                    Cookie end;
        What -> wf:info(?MODULE,"Auth Cookie Error: ~p",[What]), What
    end,
    {{ID,_},_,_,_,_} = SessionCookie,
    put(session_id,ID),
    wf:info(?MODULE,"State: ~p",[SessionCookie]),
    {ok, State, Ctx#cx{session=SessionCookie}}.

expired(_Issued,Till) -> Till < calendar:local_time().

lookup_ets(Key) ->
    Res = ets:lookup(cookies,Key),
    %wf:info(?MODULE,"Lookup ETS: ~p",[{Res,Key}]),
    case Res of
         [] -> undefined;
         [Value] -> Value;
         Values -> Values
    end.

clear() -> clear(session_id()).
clear(Session) ->
    async_stop(async, {xhrpoll, Session}),
    [ ets:delete(cookies,X) || X <- ets:select(cookies,
        ets:fun2ms(fun(A) when (element(1,element(1,A)) == Session) -> element(1,A) end)) ],
    ok.

%% 3S variant without the gen_server call to get the launch group
%% in order to avoid a race condition that occurs when sessions are gc'ed at very fast rate
%% because of multiple clear(session) calls by invalidate_sessions when they expire at the same time
%% race with gs_meeting:handle_info({'EXIT', Pid, Reason}, State) and subsequent calls
async_stop(Class, Name) ->
    Group = n2o,
    [supervisor:F(Group,{Class,Name}) || F<-[terminate_child,delete_child]],
    wf:cache({Class,Name},undefined).

cookie_expire(SecondsToLive) ->
    Seconds = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    DateTime = calendar:gregorian_seconds_to_datetime(Seconds + SecondsToLive),
    cow_date:rfc2109(DateTime).

ttl() -> wf:config(n2o,ttl,60*15).

till(Now,TTL) ->
    calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds(Now) + TTL).

session_id() -> get(session_id).

new_sid() ->
    wf_convert:hex(binary:part(crypto:hmac(wf:config(n2o,hmac,sha256),
         n2o_secret:secret(),term_to_binary(os:timestamp())),0,16)).

new_cookie_value(From) -> new_cookie_value(new_sid(), From).
new_cookie_value(undefined, From) -> new_cookie_value(new_sid(), From);
new_cookie_value(SessionKey, From) ->
    F = wf:f("document.cookie='~s=~s; path=/; expires=~s';",
                [wf:to_list(session_cookie_name(From)),
                 wf:to_list(SessionKey),
                 cookie_expire(2147483647)]),
    io:format("Cookie: ~p~n",[F]),
    wf:wire(F),
    % NOTE: Infinity-expire cookie will allow to clean up all session cookies
    %       by request from browser so we don't need to sweep them on server.
    %       Actually we should anyway to cleanup outdated cookies
    %       that will never be requested.
    SessionKey.

session_cookie_name([]) -> session_cookie_name(site);
session_cookie_name(From) -> wf:to_binary([wf:to_binary(From), <<"-sid">>]).

%% 3S don't seems to be used
%% -------------------------
%%set_session_value(Session, Key, Value) ->
%%    Till = till(calendar:local_time(), ttl()),
%%    ets:insert(cookies,{{Session,Key},<<"/">>,os:timestamp(),Till,Value}),
%%    Value.

set_value(Key, Value) ->
    set_value(session_id(), Key, Value).

set_value(SessionId, Key, Value) ->
    Lookup = case lookup_ets({SessionId,<<"auth">>}) of
        undefined ->
            session_sid(SessionId, site),
            lookup_ets({SessionId,<<"auth">>});
        Res -> Res
    end,
    {Auth_Key,Auth_Path,Auth_Issued,Auth_Till,Auth_Value} = Lookup,
    %% 3S set new auth expiration time
    NewTill = till(calendar:local_time(), ttl()),
    ets:insert(cookies,{Auth_Key,Auth_Path,Auth_Issued,NewTill,Auth_Value}),
    %% update regular key
    ets:insert(cookies,{{SessionId,Key},<<"/">>,os:timestamp(),NewTill,Value}),
    Value.

%% invalidate sessions is called by an async timer that runs every 10 mins by default
%% 3S version is based on <<"auth">> session entries only to expire session's content
%% can not rely on get_value coz behaviour is modified compared to original (prolongation)
invalidate_sessions() ->
    ets:foldl(fun(X,A) ->
        {{SessionId, Key}, _, Auth_Issued, Auth_Till, _} = X,
        case Key of
            <<"auth">> ->
                case expired(Auth_Issued,Auth_Till) of
                    true -> clear(SessionId);
                    false -> nop
                end;
            _ -> nop
        end,
        A
        end, 0, cookies).

get_value(Key, DefaultValue) ->
    get_value(session_id(), Key, DefaultValue).

%% 3S get_value is also used to prolongate sessions
%% expiration is defined based on auth sessionkey
get_value(SessionId, Key, DefaultValue) ->
    case lookup_ets({SessionId,<<"auth">>}) of
        undefined -> session_sid(SessionId, site);
        {Auth_Key,Auth_Path,Auth_Issued,Auth_Till,Auth_Value} ->
            case expired(Auth_Issued,Auth_Till) of
                false ->
                    NewTill = till(calendar:local_time(), ttl()),
                    ets:insert(cookies,{Auth_Key,Auth_Path,Auth_Issued,NewTill,Auth_Value});
                true ->
                    clear(SessionId),
                    session_sid(SessionId, site)
            end
    end,
    case lookup_ets({SessionId,Key}) of
        undefined -> DefaultValue;
        {_,_,_,_,Value} -> Value
    end.

remove_value(Key) -> ets:delete(cookies,Key).