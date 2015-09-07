using JLD2, Base.Test

immutable SingleFieldWrapper{T}
    x::T
end
Base.(:(==))(a::SingleFieldWrapper, b::SingleFieldWrapper) = a.x == b.x

immutable MultiFieldWrapper{T}
    x::T
    y::Int
end
Base.(:(==))(a::MultiFieldWrapper, b::MultiFieldWrapper) = (a.x == b.x && a.y == b.y)

immutable UntypedWrapper
    x
end
Base.(:(==))(a::UntypedWrapper, b::UntypedWrapper) = a.x == b.x

# This is a type with a custom serialization, where the original type has data
# but the custom serialization is empty
immutable CSA
    x::Ptr{Void}
end
a = CSA(Ptr{Void}(0))

immutable CSASerialization end
JLD2.writeas(::Type{CSA}) = CSASerialization
function JLD2.wconvert(::Type{CSASerialization}, x::CSA)
    global converted = true
    CSASerialization()
end
function JLD2.rconvert(::Type{CSA}, x::CSASerialization)
    global converted = true
    CSA(Ptr{Void}(0))
end

# This is a type with a custom serialization, where the original type has no
# data but the custom serialization does
immutable CSB end
b = CSB()

immutable CSBSerialization
    x::Int
end
JLD2.writeas(::Type{CSB}) = CSBSerialization
function JLD2.wconvert(::Type{CSBSerialization}, x::CSB)
    global converted = true
    CSBSerialization(9018620829326368991)
end
function JLD2.rconvert(::Type{CSB}, x::CSBSerialization)
    global converted = true
    x.x == 9018620829326368991 ? CSB() : error("invalid deserialized data")
end

# This is a type where the custom serialized data can be stored inline when it
# is a field of another type, but the original data could not
type CSC
    x::Vector{Int}
end
Base.(:(==))(a::CSC, b::CSC) = a.x == b.x
c = CSC(rand(Int, 2))

immutable CSCSerialization
    a::Int
    b::Int
end
JLD2.writeas(::Type{CSC}) = CSCSerialization
function JLD2.wconvert(::Type{CSCSerialization}, x::CSC)
    global converted = true
    CSCSerialization(x.x[1], x.x[2])
end
function JLD2.rconvert(::Type{CSC}, x::CSCSerialization)
    global converted = true
    CSC([x.a, x.b])
end

# This is a type where the original data could be stored inline when it is a
# field of another type, but the custom serialized data cannot
immutable CSD
    a::Int
    b::Int
end
d = CSD(rand(Int), rand(Int))

immutable CSDSerialization
    x::Vector{Int}
end
JLD2.writeas(::Type{CSD}) = CSDSerialization
function JLD2.wconvert(::Type{CSDSerialization}, x::CSD)
    global converted = true
    CSDSerialization([x.a, x.b])
end
function JLD2.rconvert(::Type{CSD}, x::CSDSerialization)
    global converted = true
    CSD(x.x[1], x.x[2])
end

function write_tests(file, prefix, obj)
    write(file, prefix, obj)
    write(file, "$(prefix)_singlefieldwrapper", SingleFieldWrapper(obj))
    write(file, "$(prefix)_multifieldwrapper", MultiFieldWrapper(obj, 5935250212119237787))
    write(file, "$(prefix)_untypedwrapper", UntypedWrapper(obj))
    write(file, "$(prefix)_arr", [obj])
    write(file, "$(prefix)_empty_arr", typeof(obj)[])
end

function read_tests(file, prefix, obj)
    global converted = false
    @test read(file, prefix) == obj
    @test converted
    @test read(file, "$(prefix)_singlefieldwrapper") == SingleFieldWrapper(obj)
    @test read(file, "$(prefix)_multifieldwrapper") == MultiFieldWrapper(obj, 5935250212119237787)
    @test read(file, "$(prefix)_untypedwrapper") == UntypedWrapper(obj)
    arr = read(file, "$(prefix)_arr")
    @test typeof(arr) == Vector{typeof(obj)} && length(arr) == 1 && arr[1] == obj
    empty_arr = read(file, "$(prefix)_empty_arr")
    @test typeof(empty_arr) == Vector{typeof(obj)} && length(empty_arr) == 0
end

fn = joinpath(tempdir(),"test.jld")
file = jldopen(fn, "w")
write_tests(file, "a", a)
write_tests(file, "b", b)
write_tests(file, "c", c)
write_tests(file, "d", d)
close(file)

file = jldopen(fn, "r")
read_tests(file, "a", a)
read_tests(file, "b", b)
read_tests(file, "c", c)
read_tests(file, "d", d)
close(file)