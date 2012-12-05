-module(rt53_req).
-include("../include/rt53.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("xmerl/include/xmerl.hrl").

-compile(export_all).
-export([aws_url/1]).

%%% ------------------------- External API.
-spec aws_url/1 :: (string()) -> string().
aws_url(Path) -> string:concat(?RT53_URL, Path).
                     
-spec aws_url/2 :: (default | string(), string()) -> string().
aws_url(default, Path) -> aws_url(?RT53_API, Path);
aws_url(Version, Path) -> string:join([?RT53_URL, Version, Path], "/").


%% -- ListHostedZones, pp. 17.
-spec list_hosted_zones/0 :: () -> string().
list_hosted_zones() ->
    URL = aws_url(default, "hostedzone"),
    Res = send_request(get, URL, []),
    extract_hosted_zones(Res).

-spec list_hosted_zones/2 :: (string(), string()) -> [ {atom(), string()} ] .
list_hosted_zones(Marker, MaxItems) ->                                      
    URL = aws_url(default, "hostedzone"),
    Res = send_request(get, URL, [{marker, Marker}, {maxitems, MaxItems}]),
    extract_hosted_zones(Res).

extract_hosted_zones(Res) ->
    io:format("foo~n"),
    xml_to_plist(Res, "//HostedZones/HostedZone", 
                 ["Id", "Name", "CallerReference", "Config/Comment",
                  "ResourceRecordSetCount"]).
    

%%% ------------------------- Internal Functions.
send_request(get, URL, QueryParameters) ->
    {AuthHeader, Time} = rt53_auth:authinfo(),
    Headers = [{"X-Amzn-Authorization", AuthHeader},
               {"x-amz-date", Time}],
    FullURL = append_query_parameters(URL, QueryParameters),
    {ok, {{_HTTPVersion, StatusCode, _StatusString}, _Headers, Body}} =
        httpc:request(get, {FullURL, Headers}, [], []),
    case StatusCode of
        200 -> Body;
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
    ?assert(aws_url("/path") =:= string:concat(?RT53_URL, "/path")).

sample_response() ->
    "<?xml version=\"1.0\"?>\n<ListHostedZonesResponse xmlns=\"https://route53.amazonaws.com/doc/2012-02-29/\"><HostedZones><HostedZone><Id>/hostedzone/Z1ZVH5FQY4XEIK</Id><Name>aws.mxrm.us.</Name><CallerReference>289E160D-31F0-05F6-B6D1-588B4E4160A4</CallerReference><Config><Comment>mxrm.us subdomain</Comment></Config><ResourceRecordSetCount>14</ResourceRecordSetCount></HostedZone><HostedZone><Id>/hostedzone/Z3KTWPFFPHZLKV</Id><Name>masteringchemistrymooc.com.</Name><CallerReference>8D86C9A5-6CEB-0187-A597-44693A71F7F1</CallerReference><Config/><ResourceRecordSetCount>5</ResourceRecordSetCount></HostedZone></HostedZones><IsTruncated>false</IsTruncated><MaxItems>100</MaxItems></ListHostedZonesResponse>".