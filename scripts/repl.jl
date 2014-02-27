using REPL
using Terminals

ccall(:jl_install_sigint_handler, Void, ())

(quiet,repl,startup,color_set,history) = Base.process_options(ARGS)

if repl
    if !isa(STDIN,Base.TTY)
        if !color_set
            eval(Base, :(have_color = false))
        end
        # note: currently IOStream is used for file STDIN
        if isa(STDIN,File) || isa(STDIN,IOStream)
            # reading from a file, behave like include
            eval(Base, :(is_interactive = false))
            eval(parse_input_line(readall(STDIN)))
        else
            # otherwise behave repl-like
            eval(Base, :(is_interactive = true))
            while !eof(STDIN)
                eval_user_input(parse_input_line(STDIN), true)
            end
        end
    else
        t = Terminals.Unix.UnixTerminal(get(ENV,"TERM",""),STDIN,STDOUT,STDERR)

        if !color_set
            eval(Base,:(have_color = $(hascolor(t))))
        end

        eval(Base, :(is_interactive = true))
        REPL.run_repl(t)
    end
end
if Base.have_color
    print(Base.color_normal)
end
quit()
