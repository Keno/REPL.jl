using REPL
using Terminals

is_interactive = false
isinteractive() = (is_interactive::Bool)

(quiet,repl,startup,color_set,history) = Base.process_options(ARGS)

if repl
    if !isa(STDIN,Base.TTY)
        if !color_set
            global have_color = false
        end
        # note: currently IOStream is used for file STDIN
        if isa(STDIN,File) || isa(STDIN,IOStream)
            # reading from a file, behave like include
            global is_interactive = false
            eval(parse_input_line(readall(STDIN)))
        else
            # otherwise behave repl-like
            global is_interactive = true
            while !eof(STDIN)
                eval_user_input(parse_input_line(STDIN), true)
            end
        end
        if have_color
            print(color_normal)
        end
        quit()
    end

    global is_interactive = true
    t = Terminals.Unix.UnixTerminal("xterm",STDIN,STDOUT,STDERR)
    REPL.run_repl(t)
end
quit()