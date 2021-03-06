module JLD2
using DataStructures
import Base.sizeof
export jldopen

const OBJECT_HEADER_SIGNATURE = reinterpret(UInt32, UInt8['O', 'H', 'D', 'R'])[1]

# Currently we specify that all offsets and lengths are 8 bytes
const Length = UInt64

# Currently we specify a 512 byte header
const FILE_HEADER_LENGTH = 512
const FILE_HEADER = "Julia data file (HDF5), version "
const CURRENT_VERSION = v"0.2"

struct UnsupportedVersionException <: Exception end
struct UnsupportedFeatureException <: Exception end
struct InvalidDataException <: Exception end

include("Lookup3.jl")
include("mmapio.jl")
include("misc.jl")

# RelOffset represents an HDF5 relative offset. It differs from a file offset (used
# elsewhere) in that it is relative to the superblock base address. In practice,
# this means that FILE_HEADER_LENGTH has been subtracted. `fileoffset` and
# `h5offset` convert between RelOffsets and file offsets
struct RelOffset
    offset::UInt64
end
define_packed(RelOffset)
Base.:(==)(x::RelOffset, y::RelOffset) = x === y
Base.hash(x::RelOffset) = hash(x.offset)

const UNDEFINED_ADDRESS = RelOffset(0xffffffffffffffff)
const NULL_REFERENCE = RelOffset(0)

struct JLDWriteSession{T<:Union{Dict{UInt,RelOffset},Union{}}}
    h5offset::T
    objects::Vector{Any}

    JLDWriteSession{T}() where T = new()
    JLDWriteSession{T}(h5offset, objects) where T = new(h5offset, objects)
end
JLDWriteSession() = JLDWriteSession{Dict{UInt,RelOffset}}(Dict{UInt,RelOffset}(), Any[])

mutable struct GlobalHeap
    offset::Int64
    length::Length
    free::Length
    objects::Vector{Int64}
end

abstract type H5Datatype end

struct CommittedDatatype <: H5Datatype
    header_offset::RelOffset
    index::Int
end

struct ReadRepresentation{T,ODR} end
struct CustomSerialization{T,S} end

symbol_length(x::Symbol) = ccall(:strlen, Int, (Cstring,), x)

mutable struct JLDFile{T<:IO}
    io::T
    writable::Bool
    written::Bool
    created::Bool
    datatype_locations::OrderedDict{RelOffset,CommittedDatatype}
    datatypes::Vector{H5Datatype}
    datatype_wsession::JLDWriteSession{Dict{UInt,RelOffset}}
    datasets::OrderedDict{String,RelOffset}
    jlh5type::ObjectIdDict
    h5jltype::ObjectIdDict
    jloffset::Dict{RelOffset,WeakRef}
    end_of_data::Int64
    global_heaps::Dict{RelOffset,GlobalHeap}
    global_heap::GlobalHeap
end
JLDFile(io::IO, writable::Bool, written::Bool, created::Bool) =
    JLDFile(io, writable, written, created, OrderedDict{RelOffset,CommittedDatatype}(), H5Datatype[],
            JLDWriteSession(), OrderedDict{String,RelOffset}(), ObjectIdDict(),
            ObjectIdDict(), Dict{RelOffset,WeakRef}(),
            Int64(FILE_HEADER_LENGTH + sizeof(Superblock)), Dict{RelOffset,GlobalHeap}(),
            GlobalHeap(0, 0, 0, Int64[]))

fileoffset(f::JLDFile, x::RelOffset) = Int64(x.offset + FILE_HEADER_LENGTH)
h5offset(f::JLDFile, x::Int64) = RelOffset(x - FILE_HEADER_LENGTH)

#
# File
#

function jldopen(fname::AbstractString, wr::Bool, create::Bool, truncate::Bool)
    exists = isfile(fname)
    io = MmapIO(fname, wr, create, truncate)
    f = JLDFile(io, wr, truncate, !exists || truncate)

    if !truncate
        if String(read(io, UInt8, length(FILE_HEADER))) != FILE_HEADER
            throw(ArgumentError(string('"', fname, "\" is not a JLD file")))
        end

        ver = convert(VersionNumber, read_bytestring(io))
        if ver < v"0.2"
            throw(ArgumentError("only JLD2 files are presently supported"))
        elseif ver > CURRENT_VERSION
            warn('"', fname, "\" was written in JLD file format version ", ver,
                 ", but this version of JLD supports only JLD file format ", CURRENT_VERSION,
                 ". Some or all data in the file may not be readable")
        end
    end

    if wr
        seek(io, 0)
        # Write JLD header
        write(io, FILE_HEADER)
        print(io, CURRENT_VERSION)
    end

    if !truncate
        seek(io, FILE_HEADER_LENGTH)
        superblock = read(io, Superblock)
        f.end_of_data = superblock.end_of_file_address

        root_group_offset = fileoffset(f, superblock.root_group_object_header_address)
        seek(io, root_group_offset)
        root_group = read(io, Group)
        if position(io) == f.end_of_data
            f.end_of_data = root_group_offset
        end

        for i = 1:length(root_group.names)
            name = root_group.names[i]
            offset = root_group.offsets[i]
            if name == "_types"
                types_group_offset = fileoffset(f, offset)
                seek(io, types_group_offset)
                types_group = read(io, Group)
                if position(io) == f.end_of_data
                    f.end_of_data = types_group_offset
                end

                for i = 1:length(types_group.offsets)
                    f.datatype_locations[types_group.offsets[i]] = CommittedDatatype(types_group.offsets[i], i)
                end
                resize!(f.datatypes, length(types_group.offsets))
            else
                f.datasets[name] = offset
            end
        end
    end

    f
end

function jldopen(fname::AbstractString, mode::AbstractString="r")
    mode == "r"  ? jldopen(fname, false, false, false) :
    mode == "r+" ? jldopen(fname, true, false, false) :
    mode == "a" || mode == "a+" ? jldopen(fname, true, true, false) :
    mode == "w" || mode == "w+" ? jldopen(fname, true, true, true) :
    throw(ArgumentError("invalid open mode: $mode"))
end

function Base.read(f::JLDFile, name::AbstractString)
    f.end_of_data == 0 && throw(ArgumentError("file is closed"))
    haskey(f.datasets, name) || throw(ArgumentError("file has no dataset $name"))
    read_dataset(f, f.datasets[name])
end

# Populate f.datatypes and f.jlh5types with all of the committed datatypes from
# a file. We need to do this before writing to make sure we reuse written
# datatypes.
function load_datatypes(f::JLDFile)
    dts = f.datatypes
    cdts = f.datatype_locations
    @assert length(dts) == length(cdts)
    i = 1
    for cdt in values(cdts)
        !isassigned(dts, i) && jltype(f, cdt)
        i += 1
    end
end

function Base.write(f::JLDFile, name::AbstractString, obj, wsession::JLDWriteSession=JLDWriteSession())
    f.end_of_data == 0 && throw(ArgumentError("file is closed"))
    !f.writable && throw(ArgumentError("file was opened read-only"))
    !f.written && !f.created && load_datatypes(f)
    f.written = true

    io = f.io
    seek(io, f.end_of_data)
    header_offset = write_dataset(f, obj, wsession)
    f.datasets[name] = header_offset
    nothing
end

function Base.close(f::JLDFile)
    io = f.io
    if f.written
        seek(io, f.end_of_data)

        names = String[]
        sizehint!(names, length(f.datasets)+1)
        offsets = RelOffset[]
        sizehint!(offsets, length(f.datasets)+1)

        # Write types group
        if !isempty(f.datatypes)
            push!(names, "_types")
            push!(offsets, h5offset(f, position(io)))
            write(io, Group(String[@sprintf("%08d", i) for i = 1:length(f.datatypes)],
                            collect(keys(f.datatype_locations))))
        end

        # Write root group
        root_group_object_header_address = h5offset(f, position(io))
        for (k, v) in f.datasets
            push!(names, k)
            push!(offsets, v)
        end
        write(io, Group(names, offsets))

        eof_position = position(io)
        truncate(io, eof_position)
        seek(io, FILE_HEADER_LENGTH)
        write(io, Superblock(0, FILE_HEADER_LENGTH, UNDEFINED_ADDRESS,
              eof_position, root_group_object_header_address))
    end
    f.end_of_data = 0
    close(io)
    nothing
end

include("superblock.jl")
include("object_headers.jl")
include("groups.jl")
include("dataspaces.jl")
include("attributes.jl")
include("datatypes.jl")
include("datasets.jl")
include("global_heaps.jl")
include("data.jl")

end # module
