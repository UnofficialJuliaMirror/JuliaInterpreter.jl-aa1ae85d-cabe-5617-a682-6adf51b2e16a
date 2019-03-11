using JuliaInterpreter, Test
using JuliaInterpreter: enter_call, enter_call_expr, get_return

function step_through(frame)
    r = root(frame)
    @test debug_command(JuliaInterpreter.finish_and_return!, frame, "c") === nothing
    @test r.callee === nothing
    return get_return(r)
end

@generated function generatedfoo(T)
    :(return $T)
end
callgenerated() = generatedfoo(1)

macro insert_some_calls()
    esc(quote
        x = sin(b)
        y = asin(x)
        z = sin(y)
    end)
end

# @testset "Debug" begin
    @testset "Basics" begin
        frame = enter_call(map, x->2x, 1:10)
        @test debug_command(frame, "finish") === nothing
        @test frame.caller === frame.callee === nothing
        @test get_return(frame) == map(x->2x, 1:10)

        function complicated_keyword_stuff(args...; kw...)
            args[1] == args[1]
            (args..., kw...)
        end
        for (args, kwargs) in (((1,), ()), ((1, 2), (x=7, y=33)))
            frame = enter_call(complicated_keyword_stuff, args...; kwargs...)
            f, pc = debug_command(frame, "n")
            @test f === frame
            @test isa(pc, Int)
            @test debug_command(frame, "finish") === nothing
            @test frame.caller === frame.callee === nothing
            @test get_return(frame) == complicated_keyword_stuff(args...; kwargs...)
        end

        f22() = string(:(a+b))
        @test step_through(enter_call(f22)) == "a + b"
        f22() = string(QuoteNode(:a))
        @test step_through(enter_call(f22)) == ":a"

        @test step_through(enter_call_expr(:($(+)(1,2.5)))) == 3.5
        @test step_through(enter_call_expr(:($(sin)(1)))) == sin(1)
        @test step_through(enter_call_expr(:($(gcd)(10,20)))) == gcd(10, 20)
    end

    @testset "generated" begin
        frame = enter_call_expr(:($(callgenerated)()))
        f, pc = debug_command(frame, "s")
        @test isa(pc, BreakpointRef)
        @test JuliaInterpreter.scopeof(f).name == :generatedfoo
        stmt = JuliaInterpreter.pc_expr(f)
        @test stmt.head == :return && stmt.args[1] === Int
        @test debug_command(frame, "c") === nothing
        @test frame.callee === nothing
        @test get_return(frame) === Int
        # This time, step into the generated function itself
        frame = enter_call_expr(:($(callgenerated)()))
        f, pc = debug_command(frame, "sg")
        @test isa(pc, BreakpointRef)
        @test JuliaInterpreter.scopeof(f).name == :generatedfoo
        stmt = JuliaInterpreter.pc_expr(f)
        @test stmt.head == :return && JuliaInterpreter.@lookup(f, stmt.args[1]) === 1
        f2, pc = debug_command(f, "finish")
        @test JuliaInterpreter.scopeof(f2).name == :callgenerated
        # Now finish the regular function
        @test debug_command(frame, "finish") === nothing
        @test frame.callee === nothing
        @test get_return(frame) === 1
    end

    @testset "Optional arguments" begin
        function optional(n = sin(1))
            x = asin(n)
            cos(x)
        end
        frame = JuliaInterpreter.enter_call_expr(:($(optional)()))
        # First call steps in and executes the first statement
        f, pc = debug_command(frame, "n")
        @test frame !== f
        # cos(1.0)
        debug_command(f, "n")
        # return
        f2, pc = debug_command(f, "n")
        @test f2 === frame
        @test debug_command(frame, "n") === nothing
    end

    @testset "Macros" begin
        # Work around the fact that we can't detect macro expansions if the macro
        # is defined in the same file
        include_string(Main, """
        function test_macro()
            a = sin(5)
            b = asin(a)
            @insert_some_calls
            z
        end
        ""","file.jl")
        frame = JuliaInterpreter.enter_call_expr(:($(test_macro)()))
        f, pc = debug_command(frame, "n")        # a is set
        f, pc = debug_command(f, "n")            # b is set
        f, pc = debug_command(f, "n")            # x is set
        f, pc = debug_command(f, "n")            # y is set
        f, pc = debug_command(f, "n")            # z is set
        @test debug_command(f, "n") === nothing  # return
    end

    @testset "Keyword arguments" begin
        f(x; b = 1) = x+b
        g() = f(1; b = 2)
        frame = JuliaInterpreter.enter_call_expr(:($(g)()));
        fr, pc = debug_command(frame, "nc")
        fr, pc = debug_command(fr, "nc")
        fr, pc = debug_command(fr, "nc")
        fr, pc = debug_command(fr, "s")
        fr, pc = debug_command(fr, "finish")
        @test debug_command(fr, "finish") === nothing
        @test frame.callee === nothing
        @test get_return(frame) == 3
    end

    @testset "Exceptions" begin
        # Don't break on caught exceptions
        err_caught = Any[nothing]
        function f_exc_outer()
            try 
                f_exc_inner()
            catch err;
                err_caught[1] = err
            end
            x = 1 + 1
            return x
        end
        f_exc_inner() = error()
        fr = JuliaInterpreter.enter_call(f_exc_outer)
        fr, pc =  debug_command(fr, "s")
        fr, pc =  debug_command(fr, "n")
        fr, pc =  debug_command(fr, "n")
        debug_command(fr, "finish")
        @test get_return(fr) == 2
        @test first(err_caught) isa ErrorException

        # Rethrow on uncaught exceptions
        f_outer() = g_inner()
        g_inner() = error()
        fr = JuliaInterpreter.enter_call(f_outer)
        @test_throws ErrorException debug_command(fr, "finish")

        # Break on error
        try
            JuliaInterpreter.break_on_error[] = true
            fr = JuliaInterpreter.enter_call(f_outer)
            fr, pc = debug_command(JuliaInterpreter.finish_and_return!, fr, "finish")
            @test fr.framecode.scope.name == :error
        finally
            JuliaInterpreter.break_on_error[] = false
        end
    end

# end
