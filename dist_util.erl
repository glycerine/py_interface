%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Initial Developer of the Original Code is Ericsson Utvecklings AB.
%% Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
%% AB. All Rights Reserved.''
%% 
%%     $Id$
%%
%%%----------------------------------------------------------------------
%%% Purpose : The handshake of a streamed distribution connection
%%%           in a separate file to make it usable for other
%%%           distribution protocols.
%%%----------------------------------------------------------------------

-module(dist_util).

%%-compile(export_all).
-export([handshake_we_started/1, handshake_other_started/1,
	 start_timer/1, setup_timer/2, 
	 reset_timer/1, cancel_timer/1,
	 shutdown/2]).

-import(error_logger,[error_msg/2]).

-include("dist_util.hrl").
-include("dist.hrl").

-define(to_port(FSend, Socket, Data),
	case FSend(Socket, Data) of
	    {error, closed} ->
		self() ! {tcp_closed, Socket},
	        {error, closed};
	    R ->
	        R
        end).


-define(int16(X), [((X) bsr 8) band 16#ff, (X) band 16#ff]).

-define(int32(X), 
	[((X) bsr 24) band 16#ff, ((X) bsr 16) band 16#ff,
	 ((X) bsr 8) band 16#ff, (X) band 16#ff]).

-define(i16(X1,X0),
        (?u16(X1,X0) - 
         (if (X1) > 127 -> 16#10000; true -> 0 end))).

-define(u16(X1,X0),
        (((X1) bsl 8) bor (X0))).

-define(u32(X3,X2,X1,X0),
        (((X3) bsl 24) bor ((X2) bsl 16) bor ((X1) bsl 8) bor (X0))).
-record(tick, {read = 0,
	       write = 0,
	       tick = 0,
	       ticked = 0
	       }).


handshake_other_started(HSData) ->
    {Flags,Node,Version} = recv_name(HSData),
    NewHSData = HSData#hs_data{other_flags = Flags,
			       other_version = Version,
			       other_node = Node,
			       other_started = true},
    is_allowed(NewHSData),
    mark_pending(NewHSData).
%%
%% check if connecting node is allowed to connect
%% with allow-node-scheme
%%
is_allowed(#hs_data{other_node = Node, 
		    allowed = Allowed} = HSData) ->
    case lists:member(Node, Allowed) of
	false when Allowed /= [] ->
	    send_status(HSData, not_allowed),
	    error_msg("** Connection attempt from "
		      "disallowed node ~w ** ~n", [Node]),
	    ?shutdown(Node);
	_ -> true
    end.



%% No nodedown will be sent if we fail before this process has
%% succeeded to mark the node as pending !
%%

mark_pending(#hs_data{other_node = Node} = HSData) ->
    ?debug({"MD5 connection from ~p (V~p)~n",
	    [Node, HSData#hs_data.other_version]}),
    mark_pending_2(HSData),
    {MyCookie,HisCookie} = get_cookies(Node),
    ChallengeA = gen_challenge(),
    send_challenge(HSData, ChallengeA),
    reset_timer(HSData#hs_data.timer),
    ChallengeB = 
	recv_challenge_reply(HSData, ChallengeA, MyCookie),
    send_challenge_ack(HSData, gen_digest(ChallengeB, HisCookie)),

    ?debug({dist_util, self(), accept_connection, Node}),

    connection(HSData).
    

mark_pending_2(#hs_data{kernel_pid = Kernel, 
			other_node = Node, 
			this_node = MyNode} = HSData) ->
    case do_mark_pending(Kernel,Node,
			 (HSData#hs_data.f_address)(HSData#hs_data.socket,
						    Node),
			 HSData#hs_data.other_flags) of
	ok ->
	    send_status(HSData, ok),
	    reset_timer(HSData#hs_data.timer),
	    true;

	pending ->
	    ?trace("Simultaneous connect (md5), "
		   "i am ~p, she is ~p~n", [MyNode, Node]),
	    if MyNode > Node ->
		    send_status(HSData, nok),
		    ?shutdown(Node);
	       true ->
		    send_status(HSData, ok_simultaneous),
		    do_remark_pending(Kernel, Node),
		    reset_timer(HSData#hs_data.timer),
		    true
	    end;

	up_pending ->
	    %% Check if connection is still alive, no
	    %% implies that the connection is no longer pending
	    %% due to simultaneous connect
	    do_alive(HSData),

	    %% This can happen if the other node goes down,
	    %% and goes up again and contact us before we have
	    %% detected that the socket was closed. 
	    wait_pending(Kernel),
	    reset_timer(HSData#hs_data.timer),
	    true;

	already_pending ->
	    %% FIXME: is this a case ?
	    ?debug({dist_util,self(),mark_pending2,
		    already_pending,Node}),
	    ?shutdown(Node)
    end.


%%
%% Marking pending and negotiating away 
%% simultaneous connection problems
%%

wait_pending(Kernel) ->
    receive
	{Kernel, pending} ->
	    ?trace("wait_pending returned for pid ~p.~n", 
		   [self()]),
	    ok
    end.

do_alive(#hs_data{other_node = Node} = HSData) ->
    send_status(HSData, alive),
    case recv_status(HSData) of
	true  -> true;
	false -> ?shutdown(Node)
    end.
    
do_mark_pending(Kernel,Node,Address,Flags) ->
    Kernel ! {self(), {accept_pending,Node,Address,
		       publish_type(Flags)}},
    receive
	{Kernel, {accept_pending, Ret}} ->
	    ?trace("do_mark_pending(~p,~p,~p,~p) -> ~p~n",
		   [Kernel,Node,Address,Flags,Ret]),
	    Ret
    end.

is_pending(Kernel, Node) ->
    Kernel ! {self(), {is_pending, Node}},
    receive
	{Kernel, {is_pending, Reply}} -> Reply
    end.
    
do_remark_pending(Kernel, Node) ->
    Kernel ! {self(), {remark_pending, Node}},
    receive
	{Kernel, {remark_pending, ok}} -> 
	    ok;
	{Kernel, {remark_pending, bad_request}} ->
	    %% Can not occur !!???
	    error_msg("** Simultaneous connect failed : ~p~n",
		      [Node]),
	    ?shutdown(Node)
    end.

%%
%% This will tell the net_kernel about the nodedown as it
%% recognizes the exit signal.
%% Terminate with reason shutdown so inet processes want
%% generate crash reports.
%% The termination of this process does also imply that the Socket
%% is closed in a controlled way by inet_drv.
%%

shutdown(Line, Data) ->
    flush_down(),
    exit(shutdown).
%% Use this line to debug connection.  
%% Set net_kernel verbose = 1 as well.
%%    exit({shutdown, ?MODULE, Line, Data, erlang:now()}).


flush_down() ->
    receive
	{From, get_status} ->
	    From ! {self(), get_status, error},
	    flush_down()
    after 0 ->
	    ok
    end.

handshake_we_started(#hs_data{other_node = Node,
			      other_version = Version} = HSData) ->
    send_name(HSData),
    recv_status(HSData),
    {Flags, NodeA, VersionA, ChallengeA} = recv_challenge(HSData),
    if Node =/= NodeA -> ?shutdown(no_node);
       Version =/= VersionA -> ?shutdown(no_node);
       true -> true
    end,
    NewHSData = HSData#hs_data{other_flags = Flags, 
			       other_started = false}, 
    MyChallenge = gen_challenge(),
    {MyCookie,HisCookie} = get_cookies(Node),
    send_challenge_reply(NewHSData,MyChallenge,
			 gen_digest(ChallengeA,HisCookie)),
    reset_timer(NewHSData#hs_data.timer),
    recv_challenge_ack(NewHSData, MyChallenge, MyCookie),
    connection(NewHSData).

%% --------------------------------------------------------------
%% The connection has been established.
%% --------------------------------------------------------------

connection(#hs_data{other_node = Node,
		    socket = Socket,
		    f_address = FAddress,
		    f_setopts_pre_nodeup = FPreNodeup,
		    f_setopts_post_nodeup = FPostNodeup}= HSData) ->
    cancel_timer(HSData#hs_data.timer),
    PType = publish_type(HSData#hs_data.other_flags), 
    case do_setnode(HSData) of
	error ->
	    ?shutdown(Node);
	ok ->
	    case FPreNodeup(Socket) of
		ok -> 
		    Address = FAddress(Socket,Node),
		    mark_nodeup(HSData,Address),
		    case FPostNodeup(Socket) of
			ok ->
			    con_loop(HSData#hs_data.kernel_pid, 
				     Node, 
				     Socket, 
				     Address,
				     HSData#hs_data.this_node, 
				     PType,
				     #tick{},
				     HSData#hs_data.mf_tick,
				     HSData#hs_data.mf_getstat);
			_ ->
			    ?shutdown(Node)
		    end;
		_ ->
		    ?shutdown(Node)
	    end
    end.

%% Generate a message digest from Challenge number and Cookie	
gen_digest(Challenge, Cookie) 
  when integer(Challenge), atom(Cookie) ->
    C0 = erlang:md5_init(),
    C1 = erlang:md5_update(C0, atom_to_list(Cookie)),
    C2 = erlang:md5_update(C1, integer_to_list(Challenge)),
    binary_to_list(erlang:md5_final(C2)).

%% ---------------------------------------------------------------
%% Challenge code
%% gen_challenge() returns a "random" number
%% ---------------------------------------------------------------
gen_challenge() ->
    {A,B,C} = erlang:now(),
    {D,_}   = erlang:statistics(reductions),
    {E,_}   = erlang:statistics(runtime),
    {F,_}   = erlang:statistics(wall_clock),
    {G,H,_} = erlang:statistics(garbage_collection),
    %% A(8) B(16) C(16)
    %% D(16),E(8), F(16) G(8) H(16)
    ( ((A bsl 24) + (E bsl 16) + (G bsl 8) + F) bxor
      (B + (C bsl 16)) bxor 
      (D + (H bsl 16)) ) band 16#ffffffff.

%%
%% Get the cookies for a node from auth
%%    
get_cookies(Node) ->
    case auth:get_cookie(Node) of
	X when atom(X) ->
	    {X,X};
	{Y,Z} when atom(Y), atom(Z) ->
	    {Y,Z};
	_ ->
	    erlang:fault("Corrupt cookie database")
    end.    

%%
%% Setnode works quite differently depending on handshale type:
%% With MD5 digests, cookies are already dealt with and the 
%% distribution code in the emulator need not know about them.
%% The cleartext shake on the other hand needs to
%% inform the emulator of the cookies, as they are contained in every message. 
%%
do_setnode(#hs_data{other_node = Node, socket = Socket, 
		    other_flags = Flags, other_version = Version,
		    f_getll = GetLL}) ->
    case GetLL(Socket) of
	{ok,Port} ->
	    ?trace("setnode(md5,~p ~p ~p)~n", 
		   [Node, Port, {publish_type(Flags), 
				 '(', Flags, ')', 
				 Version}]),
	    erlang:setnode(Node, Port, 
			   {Flags, Version, '', ''}),
	    ok;
	_ ->
	    error
    end.

mark_nodeup(#hs_data{kernel_pid = Kernel, 
		     other_node = Node, 
		     socket = Socket, 
		     other_flags = Flags,
		     other_started = OtherStarted}, 
	    Address) ->
    Kernel ! {self(), {nodeup,Node,Address,publish_type(Flags),
		       true}},
    receive
	{Kernel, inserted} ->
	    ok;
	{Kernel, bad_request} ->
	    TypeT = case OtherStarted of
		       true ->
			   "accepting connection";
		       _ ->
			   "initiating connection"
		   end,
	    error_msg("Fatal: ~p was not allowed to "
		      "send {nodeup, ~p} to kernel when ~s~n",
		      [self(), Node, TypeT]),
	    ?shutdown(Node)
    end.

con_loop(Kernel, Node, Socket, TcpAddress,
	 MyNode, Type, Tick, MFTick, MFGetstat) ->
    receive
	{tcp_closed, Socket} ->
	    ?shutdown(Node);
	{Kernel, disconnect} ->
	    ?shutdown(Node);
	{Kernel, tick} ->
	    case send_tick(Socket, Tick, Type, 
			   MFTick, MFGetstat) of
		{ok, NewTick} ->
		    con_loop(Kernel, Node, Socket, TcpAddress,
			     MyNode, Type, NewTick, MFTick,  
			     MFGetstat);
		{error, not_responding} ->
 		    error_msg("** Node ~p not responding **~n"
 			      "** Removing (timedout) connection **~n",
 			      [Node]),
 		    ?shutdown(Node);
		Other ->
		    ?shutdown(Node)
	    end;
	{From, get_status} ->
	    case MFGetstat(Socket) of
		{ok, Read, Write, _} ->
		    From ! {self(), get_status, {ok, Read, Write}},
		    con_loop(Kernel, Node, Socket, TcpAddress, 
			     MyNode, 
			     Type, Tick, 
			     MFTick, MFGetstat);
		_ ->
		    ?shutdown(Node)
	    end
    end.


%% ------------------------------------------------------------
%% Misc. functions.
%% ------------------------------------------------------------

send_name(#hs_data{socket = Socket, this_node = Node, 
		   f_send = FSend, 
		   this_flags = Flags,
		   other_version = Version}) ->
    ?trace("send_name: node=~w, version=~w\n",
	   [Node,Version]),
    ?to_port(FSend, Socket, 
	     [$n, ?int16(Version), ?int32(Flags), atom_to_list(Node)]).

send_challenge(#hs_data{socket = Socket, this_node = Node, 
			other_version = Version, 
			this_flags = Flags,
			f_send = FSend},
	       Challenge ) ->
    ?trace("send: challenge=~w version=~w\n",
	   [Challenge,Version]),
    ?to_port(FSend, Socket, [$n,?int16(Version), ?int32(Flags),
			     ?int32(Challenge), 
			     atom_to_list(Node)]).

send_challenge_reply(#hs_data{socket = Socket, f_send = FSend}, 
		     Challenge, Digest) ->
    ?trace("send_reply: challenge=~w digest=~p\n",
	   [Challenge,Digest]),
    ?to_port(FSend, Socket, [$r,?int32(Challenge),Digest]).

send_challenge_ack(#hs_data{socket = Socket, f_send = FSend}, 
		   Digest) ->
    ?trace("send_ack: digest=~p\n", [Digest]),
    ?to_port(FSend, Socket, [$a,Digest]).


%%
%% Get the name of the other side.
%% Close the connection if invalid data.
%% The IP address sent is not interesting (as in the old
%% tcp_drv.c which used it to detect simultaneous connection
%% attempts).
%%
recv_name(#hs_data{socket = Socket, f_recv = Recv}) ->
    case Recv(Socket, 0, infinity) of
	{ok,Data} ->
	    get_name(Data);
	_ ->
	    ?shutdown(no_node)
    end.

get_name([$n,VersionA, VersionB, Flag1, Flag2, Flag3, Flag4 | OtherNode]) ->
    {?u32(Flag1, Flag2, Flag3, Flag4), list_to_atom(OtherNode), 
     ?u16(VersionA,VersionB)};
get_name(Data) ->
    ?shutdown(Data).

publish_type(Flags) ->
    case Flags band ?DFLAG_PUBLISHED of
	0 ->
	    hidden;
	_ ->
	    normal
    end.

%% wait for challenge after connect
recv_challenge(#hs_data{socket = Socket, f_recv = Recv}) ->
    case Recv(Socket, 0, infinity) of
	{ok,[$n,V1,V0,Fl1,Fl2,Fl3,Fl4,CA3,CA2,CA1,CA0 | Ns]} ->
	    Flags = ?u32(Fl1,Fl2,Fl3,Fl4),
	    Node =list_to_atom(Ns),
	    Version = ?u16(V1,V0),
	    Challenge = ?u32(CA3,CA2,CA1,CA0),
	    ?trace("recv: node=~w, challenge=~w version=~w\n",
		   [Node, Challenge,Version]),
	    {Flags,Node,Version,Challenge};
	_ ->
	    ?shutdown(no_node)	    
    end.


%%
%% wait for challenge response after send_challenge
%%
recv_challenge_reply(#hs_data{socket = Socket, 
			      other_node = NodeB,
			      f_recv = FRecv}, 
		     ChallengeA, Cookie) ->
    case FRecv(Socket, 0, infinity) of
	{ok,[$r,CB3,CB2,CB1,CB0 | SumB]} when length(SumB) == 16 ->
	    SumA = gen_digest(ChallengeA, Cookie),
	    ChallengeB = ?u32(CB3,CB2,CB1,CB0),
	    ?trace("recv_reply: challenge=~w digest=~p\n",
		   [ChallengeB,SumB]),
	    ?trace("ChallengeA = ~w, Cookie=~p ==> sum = ~p\n",
		   [ChallengeA, Cookie, SumA]),
	    if SumB == SumA ->
		    ChallengeB;
	       true ->
		    error_msg("** Connection attempt from "
			      "disallowed node ~w ** ~n", [NodeB]),
		    ?shutdown(NodeB)
	    end;
	_ ->
	    ?shutdown(no_node)
    end.

recv_challenge_ack(#hs_data{socket = Socket, f_recv = FRecv, 
			    other_node = NodeB}, 
		   ChallengeB, CookieA) ->
    case FRecv(Socket, 0, infinity) of
	{ok,[$a | SumB]} when length(SumB) == 16 ->
	    SumA = gen_digest(ChallengeB, CookieA),
	    ?trace("recv_ack: digest=~p\n", [SumB]),
	    ?trace("sum = ~p\n", [SumA]),
	    if SumB == SumA ->
		    ok;
	       true ->
		    error_msg("** Connection attempt to "
			      "disallowed node ~w ** ~n", [NodeB]),
		    ?shutdown(NodeB)
	    end;
	_ ->
	    ?shutdown(NodeB)
    end.

recv_status(#hs_data{kernel_pid = Kernel, socket = Socket, 
		     other_node = Node, f_recv = Recv} = HSData) ->
    case Recv(Socket, 0, infinity) of
	{ok, [$s|StrStat]} ->
	    Stat = list_to_atom(StrStat),
	    ?debug({dist_util,self(),recv_status, Node, Stat}),
	    case Stat of
		not_allowed -> ?shutdown(Node);
		nok  -> 
		    %% wait to be killed by net_kernel
		    receive
		    after infinity -> ok
		    end;
		alive -> 
		    Reply = is_pending(Kernel, Node),
		    ?debug({is_pending,self(),Reply}),
		    send_status(HSData, Reply),
		    if Reply == false ->
			    ?shutdown(Node);
		       Reply == true ->
			    Stat
		    end;
		_ -> Stat
	    end;
	Error ->
	    ?debug({dist_util,self(),recv_status_error, 
		    Node, Error}),
	    ?shutdown(Node)
    end.


send_status(#hs_data{socket = Socket, other_node = Node,
		    f_send = FSend}, Stat) ->
    ?debug({dist_util,self(),send_status, Node, Stat}),
    case FSend(Socket, [$s | atom_to_list(Stat)]) of
	{error, _} ->
	    ?shutdown(Node);
	_ -> 
	    true
    end.
    
    

%%
%% Send a TICK to the other side.
%%
%% This will happen every 15 seconds (by default) 
%% The idea here is that every 15 secs, we write a little 
%% something on the connection if we haven't written anything for 
%% the last 15 secs.
%% This will ensure that nodes that are not responding due to 
%% hardware errors (Or being suspended by means of ^Z) will 
%% be considered to be down. If we do not want to have this  
%% we must start the net_kernel (in erlang) without its 
%% ticker process, In that case this code will never run 

%% And then every 60 seconds we also check the connection and 
%% close it if we havn't received anything on it for the 
%% last 60 secs. If ticked == tick we havn't received anything 
%% on the connection the last 60 secs. 

%% The detection time interval is thus, by default, 45s < DT < 75s 

%% A HIDDEN node is always (if not a pending write) ticked if 
%% we haven't read anything as a hidden node only ticks when it receives 
%% a TICK !! 
	
send_tick(Socket, Tick, Type, MFTick, MFGetstat) ->
    #tick{tick = T0,
	  read = Read,
	  write = Write,
	  ticked = Ticked} = Tick,
    T = T0 + 1,
    T1 = T rem 4,
    case MFGetstat(Socket) of
	{ok, Read, _, _} when  Ticked == T ->
	    {error, not_responding};
	{ok, Read, W, Pend} when Type == hidden ->
	    send_tick(Socket, Pend, MFTick),
	    {ok, Tick#tick{write = W + 1,
			   tick = T1}};
	{ok, Read, Write, Pend} ->
	    send_tick(Socket, Pend, MFTick),
	    {ok, Tick#tick{write = Write + 1,
			   tick = T1}};
	{ok, R, Write, Pend} ->
	    send_tick(Socket, Pend, MFTick),
	    {ok, Tick#tick{write = Write + 1,
			   read = R,
			   tick = T1,
			   ticked = T}};
	{ok, Read, W, _} ->
	    {ok, Tick#tick{write = W,
			   tick = T1}};
	{ok, R, W, _} ->
	    {ok, Tick#tick{write = W,
			   read = R,
			   tick = T1,
			   ticked = T}};
	Error ->
	    Error
    end.

send_tick(Socket, 0, MFTick) ->
    MFTick(Socket);
send_tick(_, Pend, _) ->
    %% Dont send tick if pending write.
    ok.

%% ------------------------------------------------------------
%% Connection setup timeout timer.
%% After Timeout milliseconds this process terminates
%% which implies that the owning setup/accept process terminates.
%% The timer is reset before every network operation during the
%% connection setup !
%% ------------------------------------------------------------

start_timer(Timeout) ->
    spawn_link(?MODULE, setup_timer, [self(), Timeout*?trace_factor]).

setup_timer(Pid, Timeout) ->
    receive
	{Pid, reset} ->
	    setup_timer(Pid, Timeout)
    after Timeout ->
	    ?trace("Timer expires ~p, ~p~n",[Pid, Timeout]),
	    ?shutdown(timer)
    end.

reset_timer(Timer) ->
    Timer ! {self(), reset}.

cancel_timer(Timer) ->
    unlink(Timer),
    exit(Timer, shutdown).
