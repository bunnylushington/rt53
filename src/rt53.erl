-module(rt53).
-include("../include/rt53.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("xmerl/include/xmerl.hrl").

-compile(export_all).

-export([start/0, start_link/0, stop/0]).

-export([aws_url/1, aws_url/2,
        list_hosted_zones/0, list_hosted_zones/2,
        get_hosted_zone/1,
        create_hosted_zone/1, create_hosted_zone/2, create_hosted_zone/3,
        delete_hosted_zone/1]).


%%% ------------------------- Erlang Housekeeping.
start_link() ->
    rt53_sup:start_link().

start() ->
    application:start(rt53).

stop() ->
    application:stop(rt53).


%%% ------------------------- External API.
-spec aws_url/1 :: (string()) -> string().
aws_url(Path) -> string:concat(?RT53_URL, Path).
                     
-spec aws_url/2 :: (default | string(), string()) -> string().
aws_url(default, Path) -> aws_url(?RT53_API, Path);
aws_url(Version, Path) -> string:join([?RT53_URL, Version, Path], "/").


%% -- ListHostedZones, pp. 17.
-spec list_hosted_zones/0 :: () -> hosted_zone_list().
list_hosted_zones() ->
    URL = aws_url(default, "hostedzone"),
    parse_hosted_zone_list(send_request(get, URL, [], 200)).

-spec list_hosted_zones/2 :: (string(), string()) -> hosted_zone_list().
list_hosted_zones(Marker, MaxItems) ->                                      
    URL = aws_url(default, "hostedzone"),
    Params = [{marker, Marker}, {maxitems, MaxItems}],
    parse_hosted_zone_list(send_request(get, URL, Params, 200)).
 
parse_hosted_zone_list(Res) ->
    ZoneList = xml_to_plist(Res, "//HostedZones/HostedZone", zone_attributes()),
    AttrList = xml_to_plist(Res, "/", zone_list_attributes()),
    {hd(AttrList), ZoneList}.

zone_attributes() ->
    [ "Id", "Name", "CallerReference", 
      "Config/Comment", "ResourceRecordSetCount"].

zone_list_attributes() ->
    ["Marker", "IsTruncated", "NextMarker", "MaxItems"].
         
%% -- GetHostedZone, pp. 10
-spec get_hosted_zone/1 :: (string()) -> zone_info(). 
get_hosted_zone(Zone) ->
    ZoneSpec = case lists:prefix("/hostedzone/", Zone) of
                   true -> Zone;
                   false -> "/hostedzone/" ++ Zone
               end,
    URL = aws_url(default, ZoneSpec),
    Res = send_request(get, URL, [], 200),
    PList = xml_to_plist(Res, "//HostedZone", zone_attributes()),
    NSs = extract_text(Res, "//NameServer"),
    {PList, {nameserver, NSs}}.

%% -- CreateHostedZone, pp. 3
-spec create_hosted_zone/1 :: (string()) -> new_zone_info().
create_hosted_zone(Name) ->
    create_hosted_zone(Name, binary_to_list(ossp_uuid:make(v4, text)), "").

-spec create_hosted_zone/2 :: (string(), string()) -> new_zone_info().
create_hosted_zone(Name, Comment) ->
    create_hosted_zone(Name, binary_to_list(ossp_uuid:make(v4, text)), Comment).

-spec create_hosted_zone/3 :: (string(), string(), string()) -> new_zone_info().
create_hosted_zone(Name, CallerReference, Comment) -> 
    Payload = hosted_zone_xml(Name, CallerReference, Comment),
    URL = aws_url(default, "hostedzone"),
    parse_new_hosted_zone(send_request(post, URL, Payload, 201)).

hosted_zone_xml(Name, CallerReference, Comment) ->
    Data = 
        {'CreateHostedZoneRequest', [{xmlns, ?RT53_NS}],
         [ {'Name', [Name]},
           {'CallerReference', [CallerReference]},
           {'HostedZoneConfig', [{'Comment', [Comment]}]}]},
    lists:flatten(
      io_lib:format("~s~n", [xmerl:export_simple([Data], xmerl_xml)])).

parse_new_hosted_zone(Res) ->
    ZoneInfo = xml_to_plist(Res, "//HostedZone", zone_attributes()),
    ChangeInfo = xml_to_plist(Res, "//ChangeInfo", zone_change_attributes()),
    NSs = extract_text(Res, "//NameServers/NameServer"),
    {ZoneInfo, ChangeInfo, NSs}.

zone_change_attributes() ->
    ["Id", "Status", "SubmittedAt"].

%% -- DeleteHostedZone, pp. 14
-spec delete_hosted_zone/1 :: (string()) -> term().
delete_hosted_zone(Zone) ->    
    ZoneSpec = case lists:prefix("/hostedzone/", Zone) of
                   true -> Zone;
                   false -> "/hostedzone/" ++ Zone
               end,
    URL = aws_url(default, ZoneSpec),
    send_request(delete, URL, [], 200).
    %% parse_delete_hosted_zone(send_request(delete, URL, [])).

parse_delete_hosted_zone(Res) ->
    xml_to_plist(Res, "//ChangeInfo", zone_change_attributes()).

%%% ------------------------- Internal Functions.
send_request(Method, URL, Data, ExpectedResultCode) ->
    {AuthHeader, Time} = rt53_auth:authinfo(),
    CommonHeaders = [{"X-Amzn-Authorization", AuthHeader},
                     {"x-amz-date", Time}],
    AllHeaders = case Method of 
                     post -> [{"Content-Length, length(Data)"} | CommonHeaders];
                     _    -> CommonHeaders
                 end,
    FullURL = case Method of 
                  post -> {URL, AllHeaders, "text/xml", Data};
                  _    -> {append_query_parameters(URL, Data), AllHeaders}
              end,
    {ok, {{_HTTPVersion, StatusCode, _StatusString}, _Headers, Body}} =
        httpc:request(Method, FullURL, [], []),
    case StatusCode of
        ExpectedResultCode -> Body;
        _ -> error(format_error(Body))
    end.

append_query_parameters(URL, []) -> URL;
append_query_parameters(URL, Parameters) ->
    PList = [ to_string(K) ++ "=" ++ to_string(V) || {K, V} <- Parameters ],
    URL ++ "?" ++ string:join(PList, "&").

to_string(X) when is_list(X) -> X;
to_string(X) when is_integer(X) -> integer_to_list(X);
to_string(X) when is_binary(X) -> binary_to_list(X);
to_string(X) when is_atom(X) -> atom_to_list(X).

path_to_atom(String) ->
    UpCase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    [Initial | Remainder] = hd(lists:reverse(string:tokens(String, "/"))), 
    LowerIni = string:to_lower(Initial),
    UnderStr = lists:map(fun(C) -> case lists:member(C, UpCase) of
                                       true -> [ "_", string:to_lower(C) ];
                                       false -> C
                                   end
                         end, [LowerIni | Remainder]),
    list_to_atom(lists:flatten(UnderStr)).

xml_to_plist(XMLString, BasePath, Attrs) -> 
    { XML, _Rest } = xmerl_scan:string(XMLString),
    extract_xml_nodes(xmerl_xpath:string(BasePath, XML), Attrs, []).

extract_xml_nodes([], _, Res) -> Res;
extract_xml_nodes([H | T], Attrs, Res) -> 
    PList = [ {path_to_atom(A), extract_text(H, "//" ++ A) } || A <- Attrs ],  
    extract_xml_nodes(T, Attrs, [ PList | Res ]).

format_error(Body) ->
    [ Code ] = extract_text(Body, "//Error/Code"),
    [ Msg ] = extract_text(Body, "//Error/Message"),
    "AWS Error [" ++ Code ++ "]: " ++ Msg.
 
extract_text(XMLString, XPath) ->
    XPText = to_string(XPath) ++ "/text()",
    { XML, _Rest } = case is_tuple(XMLString) of
                         false -> xmerl_scan:string(XMLString);
                         true  -> { XMLString, undefined }
                     end,
    [ Text || #xmlText{value=Text} <- xmerl_xpath:string(XPText, XML) ].
 
%% ------------------------- Tests.
aws_url_test() ->
    SingleURL = ?RT53_URL ++ "/path",
    DefaultVersionURL = string:join([?RT53_URL, ?RT53_API, "/path"], "/"),
    CustomVersionURL = string:join([?RT53_URL, "123", "/path"], "/"),
    ?assertEqual(SingleURL, aws_url("/path")),
    ?assertEqual(DefaultVersionURL, aws_url(default, "/path")),
    ?assertEqual(CustomVersionURL, aws_url("123", "/path")).

to_string_test() ->
    ?assertEqual("String", to_string("String")),
    ?assertEqual("123", to_string(123)),
    ?assertEqual("Binary", to_string(<<"Binary">>)),
    ?assertEqual("atom", to_string(atom)).

append_query_parameters_test() ->
    Params = [{a, "foo"}, {"B", "quux"}, {c, 123}],
    URL = "http://example.com/baz",
    FullURL = "http://example.com/baz?a=foo&B=quux&c=123",
    ?assertEqual(FullURL, append_query_parameters(URL, Params)),
    ?assertEqual(URL, append_query_parameters(URL, [])).
    
path_to_atom_test() ->
    ?assertEqual(foo_bar_baz, path_to_atom("FooBarBaz")),
    ?assertEqual(bar_baz, path_to_atom("Foo/BarBaz")),
    ?assertEqual(foo, path_to_atom("Foo")),
    ?assertEqual(foo_bar, path_to_atom("foo_bar")).

xml_to_plist_test() ->
    Res = xml_to_plist(sample_response(), "//HostedZones/HostedZone", ["Id"]),
    ?assert(length(Res) =:= 2),
    ?assertEqual(["/hostedzone/B"], proplists:get_value(id, hd(Res))).

extract_text_test() ->    
    Res = extract_text(sample_response(), "//Id"),
    ?assertEqual(["/hostedzone/A", "/hostedzone/B"], Res).

extract_xml_nodes_test() ->
    { XML, _ } = xmerl_scan:string(sample_response()),
    NodeList = xmerl_xpath:string("//HostedZones", XML), 
    Res = extract_xml_nodes(NodeList, ["Id"], []),
    ?assertEqual([[{id,["/hostedzone/A","/hostedzone/B"]}]], Res).

format_error_test() ->
    Res = format_error(sample_error()),
    ?assertEqual("AWS Error [InvalidInput]: The specified marker is not valid.",
                 Res).

sample_response() ->
    "<?xml version=\"1.0\"?>
      <ListHostedZonesResponse 
         xmlns=\"https://route53.amazonaws.com/doc/2012-02-29/\">
        <HostedZones>
          <HostedZone>
            <Id>/hostedzone/A</Id>
            <Name>foo.example.com.</Name>
            <CallerReference>289E160D</CallerReference>
            <Config>
               <Comment>mxrm.us subdomain</Comment>
            </Config>
            <ResourceRecordSetCount>14</ResourceRecordSetCount>
          </HostedZone>
          <HostedZone>
            <Id>/hostedzone/B</Id>
            <Name>bar.example.com.</Name>
            <CallerReference>8D86C9A5</CallerReference>
            <Config/>
            <ResourceRecordSetCount>5</ResourceRecordSetCount>
         </HostedZone>
       </HostedZones>
       <IsTruncated>false</IsTruncated>
       <MaxItems>100</MaxItems>
     </ListHostedZonesResponse>".

sample_error() ->
    "<?xml version=\"1.0\"?>
      <ErrorResponse 
        xmlns=\"https://route53.amazonaws.com/doc/2012-02-29/\">
        <Error>
          <Type>Sender</Type>
          <Code>InvalidInput</Code>
          <Message>The specified marker is not valid.</Message>
        </Error>
        <RequestId>99eb58c4</RequestId>
      </ErrorResponse>".
