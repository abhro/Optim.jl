@testset "Fminbox" begin
    # Quadratic objective function
    # For (A*x-b)^2/2
    function quadratic!(g, x, A, b)
        AtAx = A'A * x
        v = dot(x, AtAx) / 2 - dot(b' * A, x)
        if g !== nothing
            g .= AtAx .- A'b
        end
        return v
    end

    Random.seed!(1)
    N = 8
    boxl = 2.0
    # Generate a problem where the bounds-free solution lies outside of the chosen box
    function find_outbox(N, limit)
        outbox = false
        while !outbox
            # Random least squares problem
            A = randn(N, N)
            b = randn(N)
            # Useful calculation that can be re-used
            # Random starting point
            initial_x = A \ b

            # The objective
            funcg! = (g, x) -> quadratic!(g, x, A, b)
            g = similar(initial_x)
            funcg!(g, initial_x)
            # Find the minimum
            _objective = OnceDifferentiable(
                x -> funcg!(nothing, x),
                (g, x) -> funcg!(g, x),
                funcg!,
                initial_x,
            )
            results = optimize(_objective, initial_x, ConjugateGradient())
            @test Optim.converged(results)
            results = optimize(_objective, Optim.minimizer(results), ConjugateGradient())  # restart to ensure high-precision convergence
            @test Optim.converged(results)
            opt_x = Optim.minimizer(results)
            @test norm(g) < 1e-4
            if any(t -> abs(t) > boxl, opt_x)
                return _objective
            end
        end
        nothing
    end
    _objective = find_outbox(N, boxl)
    # fminbox
    l = fill(-boxl, N)
    u = fill(boxl, N)
    initial_x = (rand(N) .- 0.5) .* boxl
    for _optimizer in (ConjugateGradient(), GradientDescent(), LBFGS(), BFGS())
        debug_printing && printstyled("Solver: ", summary(_optimizer), "\n", color = :green)
        results = optimize(_objective, l, u, initial_x, Fminbox(_optimizer))
        @test Optim.converged(results)
        @test summary(results) == "Fminbox with $(summary(_optimizer))"
        opt_x = Optim.minimizer(results)
        NLSolversBase.gradient!(_objective, opt_x)
        g = NLSolversBase.gradient(_objective)
        # check first-order constrained optimality conditions
        for i = 1:N
            @test abs(g[i]) < 3e-3 ||
                  (opt_x[i] < -boxl + 1e-3 && g[i] > 0) ||
                  (opt_x[i] > boxl - 1e-3 && g[i] < 0)
        end
    end

    # Throw ArgumentError when initial guess is outside the box
    @test_throws ArgumentError optimize(_objective, l, u, 2u, Fminbox(GradientDescent()))

    # tests for #180
    results = optimize(
        _objective,
        l,
        u,
        initial_x,
        Fminbox(),
        Optim.Options(outer_iterations = 2),
    )
    @test Optim.iterations(results) == 2
    @test Optim.minimum(results) == _objective.f(Optim.minimizer(results))


    # Warn when initial condition is not in the interior of the box
    initial_x = rand([-1, 1], N) * boxl
    @test_logs (
        :warn,
        "Initial position cannot be on the boundary of the box. Moving elements to the interior.\nElement indices affected: [1, 2, 3, 4, 5, 6, 7, 8]",
    ) optimize(_objective, l, u, initial_x, Fminbox(), Optim.Options(outer_iterations = 1))

    # might fail if changes are made to Optim.jl
    # TODO: come up with a better test
    #results = Optim.optimize(_objective, initial_x, l, u, Fminbox(); optimizer_o = Optim.Options(iterations = 2))
    #@test Optim.iterations(results) == 470
    @testset "simple input" begin
        function exponential(x)
            return exp((2.0 - x[1])^2) + exp((3.0 - x[2])^2)
        end

        function exponential_gradient!(storage, x)
            storage[1] = -2.0 * (2.0 - x[1]) * exp((2.0 - x[1])^2)
            storage[2] = -2.0 * (3.0 - x[2]) * exp((3.0 - x[2])^2)
            storage
        end

        function exponential_gradient(x)
            storage = similar(x)
            storage[1] = -2.0 * (2.0 - x[1]) * exp((2.0 - x[1])^2)
            storage[2] = -2.0 * (3.0 - x[2]) * exp((3.0 - x[2])^2)
            storage
        end

        initial_x = [0.0, 0.0]
        optimize(exponential, exponential_gradient!, initial_x, BFGS())
        lb = fill(-0.1, 2)
        ub = fill(1.1, 2)
        od = OnceDifferentiable(exponential, initial_x)
        optimize(od, lb, ub, initial_x, Fminbox())
        nd = NonDifferentiable(exponential, initial_x)
        optimize(nd, lb, ub, initial_x, Fminbox(NelderMead()))
        od_forward = OnceDifferentiable(exponential, initial_x; autodiff = :forward)
        optimize(od_forward, lb, ub, initial_x, Fminbox())
        optimize(exponential, lb, ub, initial_x, Fminbox())
        optimize(exponential, exponential_gradient!, lb, ub, initial_x, Fminbox())
        optimize(od, lb, ub, initial_x)
        optimize(od_forward, lb, ub, initial_x)
        optimize(exponential, lb, ub, initial_x)
        optimize(exponential, exponential_gradient!, lb, ub, initial_x)
        @testset "inplace and autodiff keywords #616" begin
            optimize(exponential, lb, ub, initial_x, Fminbox())
            optimize(exponential, lb, ub, initial_x, Fminbox(); autodiff = :finite)
            optimize(exponential, lb, ub, initial_x, Fminbox(); autodiff = :forward)
            optimize(
                exponential,
                exponential_gradient,
                lb,
                ub,
                initial_x,
                Fminbox(),
                inplace = false,
            )
        end
        @testset "error for second order methods #616" begin
            @test_throws ArgumentError optimize(
                x -> x,
                (G, x) -> x,
                rand(1),
                rand(1),
                rand(1),
                Fminbox(Newton()),
            )
            @test_throws ArgumentError optimize(
                x -> x,
                (G, x) -> x,
                rand(1),
                rand(1),
                rand(1),
                Fminbox(NewtonTrustRegion()),
            )
        end
        @testset "allow for an Optim.Options to be passed #623" begin
            optimize(exponential, lb, ub, initial_x, Fminbox(), Optim.Options())
            optimize(
                exponential,
                exponential_gradient!,
                lb,
                ub,
                initial_x,
                Fminbox(),
                Optim.Options(),
            )
            @test_broken optimize(
                exponential,
                exponential_gradient,
                lb,
                ub,
                initial_x,
                Optim.Options(),
            )
        end
    end
end

@testset "#631" begin
    # Fminbox evaluates outside the box #861
    # https://github.com/JuliaNLSolvers/Optim.jl/issues/861
    for m in (GradientDescent(), ConjugateGradient(), BFGS(), LBFGS())
        optimize(
            x -> sqrt(x[1]),
            (g, x) -> (g[1] = 1 / (2 * sqrt(x[1]))),
            [0.0],
            [10.0],
            [1.0],
            Fminbox(m),
        )
        optimize(x -> sqrt(x[1]), [0.0], [10.0], [1.0], Fminbox(m); autodiff = :forwarddiff)
    end
end

@testset "#865" begin
    optimize(x -> sum(x), [0.0, 0.0], [2.0, 2.0], [1.0, 1.0], Fminbox(NelderMead()))
end
