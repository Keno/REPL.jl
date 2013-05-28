module REPL

    export StreamREPL, BasicREPL

    abstract AbstractREPL

    type REPLBackend
        repl_channel::RemoteRef
        response_channel::RemoteRef
        ans
    end

    function eval_user_input(ast::ANY, backend)
        iserr, lasterr, bt = false, (), nothing
        while true
            try
                if iserr
                    put(backend.response_channel,(lasterr,bt))
                    iserr, lasterr = false, ()
                else
                    ast = expand(ast)
                    ans = backend.ans
                    eval(Main,:(ans=$(ans)))
                    value = eval(Main,ast)
                    backend.ans = value
                    put(backend.response_channel,(value,nothing))
                end
                break
            catch err
                if iserr
                    println("SYSTEM ERROR: Failed to report error to REPL frontend")
                    println(err)
                end
                iserr, lasterr = true, err
                bt = catch_backtrace()
            end
        end
    end

    function parse_input_line(s::String)
        # s = bytestring(s)
        # (expr, pos) = parse(s, 1)
        # (ex, pos) = ccall(:jl_parse_string, Any,
        #                   (Ptr{Uint8},Int32,Int32),
        #                   s, int32(pos)-1, 1)
        # if !is(ex,())
        #     throw(ParseError("extra input after end of expression"))
        # end
        # expr
        ccall(:jl_parse_input_line, Any, (Ptr{Uint8},), s)
    end

    function start_repl_backend(repl_channel, response_channel)
        backend = REPLBackend(repl_channel,response_channel,nothing)
        @async begin
            while true
                (ast,show_value) = take(backend.repl_channel)
                if show_value == -1
                    # exit flag
                    break
                end
                eval_user_input(ast, backend)
            end

        end
    end

    function display_error(io::IO, er, bt)
        Base.with_output_color(:red, io) do io
            print(io, "ERROR: ")
            Base.error_show(io, er, bt)
        end
    end

    function print_repsonse(io::IO,r::AbstractREPL,val::ANY, bt, show_value, have_color)
        while true
            try
                if !is(bt,nothing)
                    display_error(io,val,bt)
                    println(io)
                    iserr, lasterr = false, ()
                else
                    if !is(val,nothing) && show_value
                        if have_color
                            print(io,answer_color(r))
                        end
                        try repl_show(io,val)
                        catch err
                            println(io,"Error showing value of type ", typeof(val), ":")
                            rethrow(err)
                        end
                        println(io)
                    end
                end
                break
            catch err
                if !is(bt,nothing)
                    println(io,"SYSTEM: show(lasterr) caused an error")
                    break
                end
                val = err
                bt = catch_backtrace()
            end
        end
        println(io)
    end

    using Terminals
    using Readline

    import Readline: char_move_left, char_move_word_left, CompletionProvider, completeLine

    type ReadlineREPL <: AbstractREPL
        t::TextTerminal
        answer_color::String
        consecutive_returns
    end

    type REPLCompletionProvider <: CompletionProvider
        r::ReadlineREPL
    end

    function complete_symbol(sym)
        # Find module
        strs = split(sym,".")
        # Maybe be smarter in the future
        context_module = Main

        mod = context_module
        lookup_module = true
        t = None
        for name in strs[1:(end-1)]
            s = symbol(name)
            if lookup_module
                if isdefined(mod,s)
                    b = mod.(s)
                    if isa(b,Module)
                        mod = b
                    elseif Base.isstructtype(typeof(b))
                        lookup_module = false
                        t = typeof(b)
                    else
                        # A.B.C where B is neither a type nor a 
                        # module. Will have to be revisited if
                        # overloading is allowed
                        return ASCIIString[]
                    end
                else 
                    # A.B.C where B doesn't exist in A. Give up
                    return ASCIIString[]
                end
            else
                # We're now looking for a type
                fields = t.names
                found = false
                for i in 1:length(fields)
                    if s == fields[i]
                        t = t.types[i]
                        if !Base.isstructtype(t)
                            return ASCIIString[]
                        end
                        found = true
                        break
                    end
                end
                if !found
                    #Same issue as above, but with types instead of modules
                    return ASCIIString[]
                end
            end
        end

        name = strs[end]

        suggestions = String[]
        if lookup_module
            # Looking for a binding in a module
            if mod == context_module
                # Also look in modules we got through `using` 
                mods = ccall(:jl_module_usings,Any,(Any,),Main)
                for mod in mods
                    syms = map(string,names(mod))
                    append!(suggestions,syms[map((x)->beginswith(x,name),syms)])
                end
                syms = map(string,names(mod,true,true))
            else 
                syms = map(string,names(mod,true,false))
            end

            append!(suggestions,syms[map((x)->beginswith(x,name),syms)])
        else
            # Looking for a member of a type
            fields = t.names
            for field in fields
                s = string(field)
                if beginswith(s,name)
                    push!(suggestions,s)
                end
            end
        end
        sort(unique(suggestions))
    end

    function completeLine(c::REPLCompletionProvider,s)
        # Find beginning of "A.B.C" expression
        prev_pos = position(s.input_buffer)
        while true
            char_move_word_left(s)
            if position(s.input_buffer) == 0 || (s.input_buffer.data[position(s.input_buffer)]!='.')
                break
            else 
                char_move_left(s)
            end
        end
        # prev_pos not prev_pos+1 since prev_pos is at the position past the 
        # last character we want to consider for completion
        ret = complete_symbol(s.input_buffer.size == 0 ? "" : 
            bytestring(s.input_buffer.data[(position(s.input_buffer)+1):(prev_pos)]))
        seek(s.input_buffer,prev_pos)
        return ret
    end

    const julia_green = "\001\033[1m\033[32m\002"
    const color_normal = Base.color_normal

    function return_callback(repl,s)
        if position(s.input_buffer) != 0 && eof(s.input_buffer) && 
            (seek(s.input_buffer,position(s.input_buffer)-1);read(s.input_buffer,Uint8)=='\n')
            repl.consecutive_returns += 1
        else
            repl.consecutive_returns = 0
        end
        ast = parse_input_line(bytestring(copy(s.input_buffer.data)))
        if repl.consecutive_returns > 0 || !isa(ast,Expr) || ast.head != :continue
            return true
        else 
            return false
        end
    end

    function run_repl(t::TextTerminal)
        repl=ReadlineREPL(t,Base.answer_color(),0)
        @async begin
            repl_channel = RemoteRef()
            response_channel = RemoteRef()
            start_repl_backend(repl_channel, response_channel)
            have_color = true
            print(t,have_color ? Base.banner_color : Base.banner_plain)
            while true
                line = takebuf_string(Readline.prompt!(t,"julia> ";complete=REPLCompletionProvider(repl),on_enter=s->return_callback(repl,s)))
                if !isempty(line)
                    ast = Base.parse_input_line(line)
                    if have_color
                        print(t,color_normal)
                    end
                    put(repl_channel, (ast,1))
                    (val, bt) = take(response_channel)
                    print_repsonse(repl,val,bt,true,have_color)
                end
            end
        end
    end

    type BasicREPL <: AbstractREPL
    end

    type StreamREPL <: AbstractREPL
        stream::IO
        prompt_color::String
        input_color::String
        answer_color::String
    end

    answer_color(r::ReadlineREPL) = r.answer_color
    answer_color(r::StreamREPL) = r.answer_color
    answer_color(::BasicREPL) = Base.text_colors[:white]

    print_repsonse(r::StreamREPL,args...) = print_repsonse(r.stream,r, args...)
    print_repsonse(r::ReadlineREPL,args...) = print_repsonse(r.t,r, args...)

    function run_repl(stream::AsyncStream)
    repl = StreamREPL(stream,julia_green,Base.text_colors[:white],Base.answer_color())
    @async begin
        repl_channel = RemoteRef()
        response_channel = RemoteRef()
        start_repl_backend(repl_channel, response_channel)
        have_color = true
        print(stream,have_color ? Base.banner_color : Base.banner_plain)
        while stream.open
            if have_color
                print(stream,repl.prompt_color)
            end
            print(stream,"julia> ")
            if have_color
                print(stream,repl.input_color)
            end
            line = readline(stream)
            if !isempty(line)
                ast = Base.parse_input_line(line)
                if have_color
                    print(stream,color_normal)
                end
                put(repl_channel, (ast,1))
                (val, bt) = take(response_channel)
                print_repsonse(repl,val,bt,true,have_color)
            end
        end
        # Terminate Backend
        put(repl_channel,(nothing,-1))
    end
    repl
    end

    function start_repl_server(port)
        listen(port) do server, status
            client = accept(server)
            run_repl(client)
        end
    end
end