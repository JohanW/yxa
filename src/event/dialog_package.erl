%%%-------------------------------------------------------------------
%%% File    : dialog_package.erl
%%% Author  : Fredrik Thulin <ft@it.su.se>
%%% Descrip.: Basic RFC4235 implementation.
%%%
%%% Created :  8 May 2006 by Fredrik Thulin <ft@it.su.se>
%%%-------------------------------------------------------------------
-module(dialog_package).

-behaviour(event_package).

%%--------------------------------------------------------------------
%%% Standard YXA Event package exports
%%--------------------------------------------------------------------
-export([
	 init/0,
	 request/7,
	 is_allowed_subscribe/10,
	 notify_content/4,
	 package_parameters/2,
	 subscription_behaviour/3,

	 test/0
	]).


%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("siprecords.hrl").
-include("event.hrl").
-include_lib("xmerl/include/xmerl.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------
-record(my_state, {entity,	%% string(), dialog-info entity
		   version = 1	%% integer(), dialog-info version
		  }).

-record(dialog_entry, {id,	%% string()
		       xml	%% string()
		      }).


%%====================================================================
%% Behaviour functions
%% Standard YXA Event package callback functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init()
%% Descrip.: YXA event packages export an init/0 function.
%% Returns : none | {append, SupSpec}
%%           SupSpec = OTP supervisor child specification. Extra
%%                     processes this event package want the
%%                     sipserver_sup to start and maintain.
%%--------------------------------------------------------------------
init() ->
    none.

%%--------------------------------------------------------------------
%% Function: request("dialog", Request, Origin, LogStr, LogTag,
%%                   THandler, SIPuser)
%%           Request  = request record(), the SUBSCRIBE request
%%           Origin   = siporigin record()
%%           LogStr   = string(), describes the request
%%           LogTag   = string(), log prefix
%%           THandler = term(), server transaction handler
%%           Ctx      = event_ctx record(), context information for
%%                      request.
%% Descrip.: YXA event packages must export a request/7 function.
%%           See the eventserver.erl module description for more
%%           information about when this function is invoked.
%% Returns : void(), but return 'ok' or {error, Reason} for now
%%--------------------------------------------------------------------
request("dialog", _Request, _Origin, _LogStr, LogTag, _THandler, #event_ctx{sipuser = undefined}) ->
    logger:log(debug, "~s: dialog event package: Requesting authorization (only local users allowed)",
	       [LogTag]),
    {error, need_auth};

request("dialog", #request{method = "NOTIFY"} = Request, _Origin, _LogStr, LogTag, THandler, Ctx) ->
    %% non-empty SIP user

    #event_ctx{sipuser    = User,
	       presentity = Presentity
	      } = Ctx,

    logger:log(normal, "~s: dialog event package: Processing NOTIFY ~s ({user, ~p}, presentity : ~p)",
	       [LogTag, sipurl:print(Request#request.uri), User, Presentity]),

    XML = binary_to_list(Request#request.body),

    UseExpires = util:timestamp() + 1000,	%% XXX FIX THIS, USES STATIC EXPIRATION TIME
    Flags = [],

    {ok, _Version, _Entity, Dialogs} = parse_xml(XML),

    F =
	fun(DE) when is_record(DE, dialog_entry) ->
		ETag = DE#dialog_entry.id,
		%% XXX DO THIS IN ONE TRANSACTION TO NOT GET TWO NOTIFYS SENT
		{atomic, ok}, database_eventdata:delete_using_presentity_etag(Presentity, ETag),
		{atomic, ok} = database_eventdata:insert("dialog", Presentity, ETag, UseExpires, Flags, DE)
	end,

    [F(E) || E <- Dialogs], 
		
    transactionlayer:send_response_handler(THandler, 200, "Ok"),

    ok;

request("dialog", _Request, _Origin, LogStr, LogTag, THandler, _Ctx) ->
    logger:log(normal, "~s: dialog event package: ~s -> '501 Not Implemented'",
	       [LogTag, LogStr]),
    transactionlayer:send_response_handler(THandler, 501, "Not Implemented"),
    ok.


%%--------------------------------------------------------------------
%% Function: is_allowed_subscribe("dialog", Num, Request, Origin,
%%                                LogStr, LogTag, THandler, SIPuser,
%%                                PkgState)
%%           Num      = integer(), the number of subscribes we have
%%                      received on this dialog, starts at 1
%%           Request  = request record(), the SUBSCRIBE request
%%           Origin   = siporigin record()
%%           LogStr   = string(), describes the request
%%           LogTag   = string(), log prefix
%%           THandler = term(), server transaction handler
%%           SIPuser  = undefined | string(), undefined if request
%%                      originator is not not authenticated, and
%%                      string() if the user is authenticated (empty
%%                      string if user could not be authenticated)
%%           PkgState = undefined | my_state record()
%% Descrip.: YXA event packages must export an is_allowed_subscribe/8
%%           function. This function is called when the event server
%%           receives a subscription request for this event package,
%%           and is the event packages chance to decide wether the
%%           subscription should be accepted or not. It is also called
%%           for every time the subscription is refreshed by the
%%           subscriber.
%% Returns : {error, need_auth} |       Request authentication
%%           {ok, SubState, Status, Reason, ExtraHeaders,
%%                NewPkgState}  |
%%           {siperror, Status, Reason, ExtraHeaders}
%%           SubState     = active | pending
%%           Status       = integer(), SIP status code to respond with
%%           Reason       = string(), SIP reason phrase
%%           ExtraHeaders = list() of {Key, ValueList} to include in
%%                          the response to the SUBSCRIBE
%%           Body         = binary() | list(), body of response
%%           NewPkgState  = my_state record()
%%--------------------------------------------------------------------
%%
%% SIPuser = undefined
%%
is_allowed_subscribe("dialog", _Num, _Request, _Origin, _LogStr, _LogTag, _THandler, _SIPuser = undefined, _Presentity,
		     _PkgState) ->
    {error, need_auth};
%%
%% Presentity is {users, UserList}
%%
is_allowed_subscribe("dialog", _Num, _Request, _Origin, _LogStr, LogTag, _THandler, SIPuser,
		     {users, ToUsers} = _Presentity, _PkgState) when is_list(LogTag), is_list(SIPuser),
								     is_list(ToUsers) ->
    %% For the dialog package to work when the presentity is one or more users,
    %% we have to implement the following :
    %%
    %%   Subscribe to every registered contact for the user(s) using the 'dialog' event package
    %%   Monitor the location database for changes to the user(s), and monitor all new contacts registered
    %%
    logger:log(normal, "~s: dialog event package: User presentitys not supported (yet), answering '403 Forbidden'",
	       [LogTag]),
    {siperror, 403, "Forbidden", []};
%%
%% Presentity is {address, AddressStr}
%%
is_allowed_subscribe("dialog", _Num, Request, _Origin, _LogStr, _LogTag, _THandler, SIPuser,
		     {address, AddressStr} = _Presentity, PkgState) when is_list(SIPuser), is_list(AddressStr) ->
    is_allowed_subscribe2(Request, pending, 202, "Ok", [], PkgState).

is_allowed_subscribe2(Request, SubState, Status, Reason, ExtraHeaders, PkgState) when is_record(PkgState, my_state);
										      PkgState == undefined ->
    Header = Request#request.header,
    Accept = get_accept(Header),
    case lists:member("application/dialog-info+xml", Accept) of
	true ->
	    NewPkgState =
		case PkgState of
		    #my_state{} ->
			PkgState;
		    undefined ->
			#my_state{entity = sipurl:print(Request#request.uri)}
		end,
	    Body = <<>>,
	    {ok, SubState, Status, Reason, ExtraHeaders, Body, NewPkgState};
	false ->
	    {siperror, 406, "Not Acceptable", []}
    end.


%%--------------------------------------------------------------------
%% Function: notify_content("dialog", Presentity, LastAccept,
%%                          PkgState)
%%           Presentity = {users, UserList} | {address, AddressStr}
%%               UserList = list() of string(), SIP usernames
%%             AddressStr = string(), parseable with sipurl:parse/1
%%           LastAccept = list() of string(), Accept: header value
%%                        from last SUBSCRIBE
%%           PkgState   = my_state record()
%% Descrip.: YXA event packages must export a notify_content/3
%%           function. Whenever the subscription requires us to
%%           generate a NOTIFY request, this function is called to
%%           generate the body and extra headers to include in the
%%           NOTIFY request.
%% Returns : {ok, Body, ExtraHeaders, NewPkgState} |
%%           {error, Reason}
%%           Body         = io_list()
%%           ExtraHeaders = list() of {Key, ValueList} to include in
%%                          the NOTIFY request
%%           Reason       = string() | atom()
%%           NewPkgState  = my_state record()
%%--------------------------------------------------------------------
notify_content("dialog", {address, "sip:shared@eventserver.yxa.sipit.net:5010"}, LastAccept, PkgState) when is_record(PkgState, my_state) ->
    notify_content("dialog", {address, "sip:shared@yxa.sipit.net"}, LastAccept, PkgState);

notify_content("dialog", Presentity, _LastAccept, PkgState) when is_record(PkgState, my_state) ->
    #my_state{entity  = Entity,
	      version = Version
	     } = PkgState,

    DialogsXML =
	case database_eventdata:fetch_using_presentity(Presentity) of
	    {ok, Dialogs} when is_list(Dialogs) ->
		[(E#eventdata_dbe.data)#dialog_entry.xml || E <- Dialogs];
	    nomatch ->
		""
	end,

    XML =
	"<?xml version=\"1.0\"?>\n"
	"<dialog-info xmlns=\"urn:ietf:params:xml:ns:dialog-info\"\n"
	"             version=\"" ++ integer_to_list(Version) ++ "\" state=\"full\"\n"
	"             entity=\"" ++ Entity ++ "\">\n" ++
	DialogsXML ++
	"</dialog-info>\n",

    ExtraHeaders = [{"Content-Type", ["application/dialog-info+xml"]}],

    %% XXX PERHAPS WE SHOULD ONLY INCREMENT VERSION ON CHANGED OUTPUT, CHECK SPEC
    NewPkgState = PkgState#my_state{version = Version + 1},
    {ok, XML, ExtraHeaders, NewPkgState}.


%%--------------------------------------------------------------------
%% Function: package_parameters("dialog", Param)
%%           Param = atom()
%% Descrip.: YXA event packages must export a package_parameters/2
%%           function. 'undefined' MUST be returned for all unknown
%%           parameters.
%% Returns : Value | undefined
%%           Value = term()
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: package_parameters("dialog", notification_rate_limit)
%% Descrip.: The minimum amount of time that should pass between
%%           NOTIFYs we send about this event packages events.
%% Returns : MilliSeconds = integer()
%%--------------------------------------------------------------------
package_parameters("dialog", notification_rate_limit) ->
    %% RFC4235 #3.10 (Rate of Notifications)
    1000;  %% 1000 milliseconds, 1 second

%%--------------------------------------------------------------------
%% Function: package_parameters("dialog", request_methods)
%% Descrip.: What SIP methods this event packages request/7 function
%%           can handle.
%% Returns : Methods = list() of string()
%%--------------------------------------------------------------------
package_parameters("dialog", request_methods) ->
    ["PUBLISH"];

%%--------------------------------------------------------------------
%% Function: package_parameters("dialog",
%%                              subscribe_accept_content_types)
%% Descrip.: What Content-Type encodings we should list as acceptable
%%           in the SUBSCRIBEs we send.
%% Returns : ContentTypes = list() of string()
%%--------------------------------------------------------------------
package_parameters("dialog", subscribe_accept_content_types) ->
    ["application/dialog-info+xml"];

package_parameters("dialog", _Param) ->
    undefined.


%%--------------------------------------------------------------------
%% Function: subscription_behaviour("dialog", Param, Argument)
%%           Param = atom()
%%           Argument = term(), depending on Param
%% Descrip.: YXA event packages must export a sbuscription_behaviour/2
%%           function. 'undefined' MUST be returned for all unknown
%%           parameters.
%% Returns : Value | undefined
%%           Value = term()
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: subscription_behaviour("dialog", bidirectional_subscribe,
%%                                  Request)
%%           Request = request record()
%% Descrip.: When we receive a SUBSCRIBE, should the subscription
%%           handler also SUBSCRIBE to the other side in the same
%%           dialog? For the dialog package, this is always true.
%% Returns : true
%%--------------------------------------------------------------------
subscription_behaviour("dialog", bidirectional_subscribe, Request) when is_record(Request, request) ->
    true;

subscription_behaviour("dialog", _Param, _Argument) ->
    undefined.

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: get_accept(Header)
%%           Header = keylist record()
%% Descrip.: Get Accept: header value (or default) from a header.
%% Returns : list() of string()
%%--------------------------------------------------------------------
get_accept(Header) ->
    case keylist:fetch('accept', Header) of
	[] ->
	    %% RFC4235 #3.5
	    ["application/dialog-info+xml"];
	AcceptV ->
	    [http_util:to_lower(Elem) || Elem <- AcceptV]
    end.


parse_xml(XML) ->
    try xmerl_scan:string(XML, [{namespace_conformant, true}]) of
	{XMLtag, []} ->
	    try parse_dialog_xml(XMLtag) of
		{ok, Version, Entity, Dialogs} ->
		    {ok, Version, Entity, Dialogs}
	    catch
		error : Y ->
		    ST = erlang:get_stacktrace(),
		    logger:log(error, "dialog event package: Could not parse dialog-xml data,~ncaught error : "
			       "~p ~p", [Y, ST]),
		    {error, bad_xml};
		X : Y ->
		    logger:log(error, "dialog event package: Could not parse dialog-xml data, caught ~p ~p", [X, Y]),
		    {error, bad_xml}
	    end;
	Unknown ->
	    logger:log(error, "dialog event package: Could not parse dialog XML document : ~p", [Unknown]),
	    {error, bad_xml}
    catch
	X: Y ->
	    logger:log(error, "dialog event package: Could not parse dialog XML document, caught ~p ~p",
		       [X, Y]),
	    {error, bad_xml}
    end.

%% Returns : {ok, PIDF_Doc} | {error, Reason}
%%           PIDF_Doc = pidf_doc record()
%%           Reason   = atom()
parse_dialog_xml(#xmlElement{name = 'dialog-info'} = XML) ->
    parse_dialog_xml2(XML);
parse_dialog_xml(#xmlElement{expanded_name = {_URI, 'dialog-info'}} = XML) ->
    parse_dialog_xml2(XML).

parse_dialog_xml2(XML) ->
    [Entity] = get_xml_attributes(entity, XML#xmlElement.attributes),
    [Version] = get_xml_attributes(version, XML#xmlElement.attributes),

    Dialogs = get_xml_elements(dialog, XML#xmlElement.content),

    PidStr = pid_to_list(self()),
    IdPrefix = lists:reverse(
		 lists:foldl(fun($<, Acc) -> Acc;
				($>, Acc) -> Acc;
				(C, Acc) ->
				     [C | Acc]
			     end, [], PidStr)
		),
    
    
    F = fun(E) when is_record(E, xmlElement) ->
		Id = get_xml_attributes(id, E#xmlElement.attributes),
		NewId = lists:flatten( lists:concat([IdPrefix, "-", Id]) ),

		%% replace dialog id value in xml record
		NewAttrs = [case A#xmlAttribute.name of
				id ->
				    A#xmlAttribute{value = NewId};
				_  ->
				    A
			    end || A <- E#xmlElement.attributes],
		E2 = E#xmlElement{attributes = NewAttrs},

		XML_Str = xmerl:export_simple_content([E2], presence_xmerl_xml),

		#dialog_entry{id  = NewId,
			      xml = lists:flatten(XML_Str)
			     }
	end,

    XMLDialogs = [F(E) || E <- Dialogs],

    {ok, Version, Entity, XMLDialogs}.


%%--------------------------------------------------------------------
%% Function: get_xml_attributes(Name, In)
%%           Name = atom()
%%           In   = list() of term()
%% Descrip.: Look for xmlAttribute record() with name matching Name.
%%           Extract the value elements of the xmlAttribute records
%%           matching.
%% Returns : Values = list() of string()
%%--------------------------------------------------------------------
get_xml_attributes(Name, In) when is_atom(Name), is_list(In) ->
    get_xml_attributes2(Name, In, []).

get_xml_attributes2(Name, [#xmlAttribute{name = Name} = H | T], Res) ->
    This = H#xmlAttribute.value,
    get_xml_attributes2(Name, T, [This | Res]);
get_xml_attributes2(Name, [_H | T], Res) ->
    get_xml_attributes2(Name, T, Res);
get_xml_attributes2(_Name, [], Res) ->
    lists:reverse(Res).


%%--------------------------------------------------------------------
%% Function: get_xml_elements(Name, In)
%%           Name = atom()
%%           In   = list() of term()
%% Descrip.: Look for xmlElement record() with name matching Name.
%%           Return all matching xmlElement records.
%% Returns : Elements = list() of xmlElement record()
%%--------------------------------------------------------------------
get_xml_elements(Name, In) when is_atom(Name), is_list(In) ->
    get_xml_elements2(Name, In, []).

get_xml_elements2(Name, [#xmlElement{name = Name} = H | T], Res) ->
    get_xml_elements2(Name, T, [H | Res]);
get_xml_elements2(Name, [#xmlElement{expanded_name = {_URI, Name}} = H | T], Res) ->
    get_xml_elements2(Name, T, [H | Res]);
get_xml_elements2(Name, [_H | T], Res) ->
    get_xml_elements2(Name, T, Res);
get_xml_elements2(_Name, [], Res) ->
    lists:reverse(Res).




%%====================================================================
%% Test functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: test()
%% Descrip.: autotest callback
%% Returns : ok
%%--------------------------------------------------------------------
test() ->

    %% parse_xml/1
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "parse_xml/1 - 1"),
    ParseXML1 = 
	"<?xml version=\"1.0\"?>"
	"<dialog-info xmlns=\"urn:ietf:params:xml:ns:dialog-info\""
	"  version=\"0\""
	"  state=\"full\""
	"  entity=\"sip:dialog1@yxa.sipit.net\">"
	"</dialog-info>",

    {ok, "0", "sip:dialog1@yxa.sipit.net", []} = parse_xml(ParseXML1),


    autotest:mark(?LINE, "parse_xml/1 - 2"),
    ParseXML2 =
	"<?xml version=\"1.0\"?>"
	"<dialog-info xmlns=\"urn:ietf:params:xml:ns:dialog-info\" version=\"0\" state=\"full\" "
	"  entity=\"sip:dialog1@yxa.sipit.net\">"
	"  <dialog id=\"(null)\""
	"          call-id=\"M2RhNTcxZTFkYjMwZmE1ZjMwY2E4MmU2OGI2NzdmYzE.\""
	"          local-tag=\"22175\""
	"          remote-tag=\"d5353f75\""
	"          direction=\"recipient\">"
	"    <state>terminated</state>"
	"    <local>"
	"      <identity>sip:dialog1@yxa.sipit.net</identity>"
	"      <target uri=\"sip:line0@132.177.126.87:5065\">"
	"        <param pname=\"x-line-id\" pvalue=\"0\" />"
	"      </target>"
	"    </local>"
	"    <remote>"
	"      <identity>sip:ft@yxa.sipit.net</identity>"
	"      <target uri=\"sip:ft@132.177.127.231:1237;transport=TCP\">"
	"      </target>"
	"    </remote>"
	"  </dialog>"
	"</dialog-info>",

    ParseXML2_Dialogs =
	["<dialog id=\"(null)\" call-id=\"M2RhNTcxZTFkYjMwZmE1ZjMwY2E4MmU2OGI2NzdmYzE.\" local-tag=\"22175\""
	 " remote-tag=\"d5353f75\" direction=\"recipient\">    <state>terminated</state>    <local>      <id"
	 "entity>sip:dialog1@yxa.sipit.net</identity>      <target uri=\"sip:line0@132.177.126.87:5065\">   "
	 "     <param pname=\"x-line-id\" pvalue=\"0\"/>      </target>    </local>    <remote>      <identi"
	 "ty>sip:ft@yxa.sipit.net</identity>      <target uri=\"sip:ft@132.177.127.231:1237;transport=TCP\">"
	 "      </target>    </remote>  </dialog>"],
    {ok, "0", "sip:dialog1@yxa.sipit.net", ParseXML2_Dialogs} = parse_xml(ParseXML2),
    
    ok.
