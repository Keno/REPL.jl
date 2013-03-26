module REPL

    abstract AbstractREPL

    function eval_user_input(ast::ANY, response_channel)
        iserr, lasterr, bt = false, (), nothing
        while true
            try
                if iserr
                    put(response_channel,(lasterr,bt))
                    iserr, lasterr = false, ()
                else
                    ast = expand(ast)
                    value = eval(Main,ast)
                    global ans = value
                    put(response_channel,(value,nothing))
                end
                break
            catch err
                if iserr
                    println("SYSTEM ERROR: Failed to report error to REPL frontend")
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
        @async begin
            while true
                (ast,show_value) = take(repl_channel)
                if show_value == -1
                    # exit flag
                    break
                end
                eval_user_input(ast, response_channel)
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
                            print(io,r.answer_color)
                        end
                        try repl_show(io,val)
                        catch err
                            println(io,"Error showing value of type ", typeof(value), ":")
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

    type StreamREPL <: AbstractREPL
        stream::AsyncStream
        prompt_color::String
        input_color::String
        answer_color::String
    end

    print_repsonse(r::StreamREPL,args...) = print_repsonse(r.stream,r, args...)

    const julia_green = "\001\033[1m\033[32m\002"
    const color_normal = Base.color_normal

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