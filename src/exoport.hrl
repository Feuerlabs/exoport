%%% -*- coding: latin-1 -*-
%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2013, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%% @author Malotte W L�nne <malotte@malotte.net>
%%% @copyright (C) 2013, Tony Rogvall
%%% @doc
%%%    Defines needed for exoport.
%%%
%%% Created : June 2013 by Malotte W L�nne
%%% @end
%%%-------------------------------------------------------------------
-ifndef(EXOPORT_HRL).
-define(EXOPORT_HRL, true).

-type connection_state() :: active | inactive.

%% Convenience defines 
-ifndef(ee).
-define(ee(String, List), error_logger:error_msg(String, List)).
-endif.
-ifndef(ei).
-define(ei(String, List),  error_logger:info_msg(String, List)).
-endif.

-endif.
