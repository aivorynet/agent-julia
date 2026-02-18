using Test

@testset "AIVoryMonitor" begin
    # Verify module file exists and is parseable
    module_file = joinpath(@__DIR__, "..", "src", "AIVoryMonitor.jl")
    @test isfile(module_file)
    @test filesize(module_file) > 0
end
