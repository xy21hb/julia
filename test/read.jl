# This file is a part of Julia. License is MIT: https://julialang.org/license

using DelimitedFiles

mktempdir() do dir

tasks = []

# Create test file
filename = joinpath(dir, "file.txt")
text = "C1,C2\n1,2\na,b\n"

# List of IO producers
l = Vector{Tuple{AbstractString,Function}}()


# File
io = (text) -> begin
    write(filename, text)
    Base.Filesystem.open(filename, Base.Filesystem.JL_O_RDONLY)
end
s = io(text)
@test isa(s, IO)
@test isa(s, Base.Filesystem.File)
close(s)
push!(l, ("File", io))


# IOStream
io = (text) -> begin
    write(filename, text)
    open(filename)
end
s = io(text)
@test isa(s, IO)
@test isa(s, IOStream)
close(s)
push!(l, ("IOStream", io))


# IOBuffer
io = (text)->IOBuffer(text)
s = io(text)
@test isa(s, IO)
@test isa(s, IOBuffer)
close(s)
push!(l, ("IOBuffer", io))


function run_test_server(srv, text)
    push!(tasks, @async begin
        try
            sock = accept(srv)
            try
                write(sock,text)
            catch e
                if typeof(e) != Base.UVError
                    rethrow(e)
                end
            finally
                close(sock)
            end
        finally
            close(srv)
        end
    end)
    yield()
end


# TCPSocket
io = (text) -> begin
    port, srv = listenany(rand(2000:4000))
    run_test_server(srv, text)
    connect(port)
end
s = io(text)
@test isa(s, IO)
@test isa(s, TCPSocket)
close(s)
push!(l, ("TCPSocket", io))


# PipeEndpoint
io = (text) -> begin
    a = "\\\\.\\pipe\\uv-test-$(randstring(6))"
    b = joinpath(dir, "socket-$(randstring(6))")
    socketname = Sys.iswindows() ? a : b
    srv = listen(socketname)
    run_test_server(srv, text)
    connect(socketname)
end
s = io(text)
@test isa(s, IO)
@test isa(s, Base.PipeEndpoint)
close(s)
push!(l, ("PipeEndpoint", io))

#FIXME See https://github.com/JuliaLang/julia/issues/14747
#      Reading from open(::Command) seems to deadlock on Linux/Travis
#=
if !Sys.iswindows()

# Windows type command not working?
# See "could not spawn `type 'C:\Users\appveyor\AppData\Local\Temp\1\jul3516.tmp\file.txt'`"
#https://ci.appveyor.com/project/StefanKarpinski/julia/build/1.0.12733/job/hpwjs4hmf03vs5ag#L1244

# Pipe
io = (text) -> begin
    write(filename, text)
    open(`$(Sys.iswindows() ? "type" : "cat") $filename`)[1]
#    Was open(`echo -n $text`)[1]
#    See https://github.com/JuliaLang/julia/issues/14747
end
s = io(text)
@test isa(s, IO)
@test isa(s, Pipe)
close(s)
push!(l, ("Pipe", io))

end
=#


open_streams = []
function cleanup()
    for s_ in open_streams
        try close(s_) end
    end
    empty!(open_streams)
    for tsk in tasks
        wait(tsk)
    end
    empty!(tasks)
end


verbose = false

for (name, f) in l
    local f
    local function io(text=text)
        local s = f(text)
        push!(open_streams, s)
        return s
    end

    verbose && println("$name readuntil...")
    for (t, s, m) in [
            ("a", "ab", "a"),
            ("b", "ab", "b"),
            ("α", "αγ", "α"),
            ("ab", "abc", "ab"),
            ("bc", "abc", "bc"),
            ("αβ", "αβγ", "αβ"),
            ("aaabc", "ab", "aaab"),
            ("aaabc", "ac", "aaabc"),
            ("aaabc", "aab", "aaab"),
            ("aaabc", "aac", "aaabc"),
            ("αααβγ", "αβ", "αααβ"),
            ("αααβγ", "ααβ", "αααβ"),
            ("αααβγ", "αγ", "αααβγ"),
            ("barbarbarians", "barbarian", "barbarbarian")]
        local t, s, m
        @test readuntil(io(t), s) == m
        @test readuntil(io(t), SubString(s, start(s), endof(s))) == m
        @test readuntil(io(t), GenericString(s)) == m
        @test readuntil(io(t), unsafe_wrap(Vector{UInt8},s)) == unsafe_wrap(Vector{UInt8},m)
        @test readuntil(io(t), collect(s)::Vector{Char}) == Vector{Char}(m)
    end
    cleanup()

    write(filename, text)

    verbose && println("$name read...")
    @test read(io(), UInt8) == read(IOBuffer(text), UInt8)
    @test read(io(), UInt8) == read(filename, UInt8)
    @test read(io(), Int) == read(IOBuffer(text), Int)
    @test read(io(), Int) == read(filename,Int)
    s1 = io()
    s2 = IOBuffer(text)
    @test read!(s1, Vector{UInt32}(uninitialized, 2)) == read!(s2, Vector{UInt32}(uninitialized, 2))
    @test !eof(s1)
    @test read!(s1, Vector{UInt8}(uninitialized, 5)) == read!(s2, Vector{UInt8}(uninitialized, 5))
    @test !eof(s1)
    @test read!(s1, Vector{UInt8}(uninitialized, 1)) == read!(s2, Vector{UInt8}(uninitialized, 1))
    @test eof(s1)
    @test_throws EOFError read(s1, UInt8)
    @test eof(s1)
    close(s1)
    close(s2)

    verbose && println("$name eof...")
    n = length(text) - 1
    @test read!(io(), Vector{UInt8}(uninitialized, n)) ==
          read!(IOBuffer(text), Vector{UInt8}(uninitialized, n))
    @test (s = io(); read!(s, Vector{UInt8}(uninitialized, n)); !eof(s))
    n = length(text)
    @test read!(io(), Vector{UInt8}(uninitialized, n)) ==
          read!(IOBuffer(text), Vector{UInt8}(uninitialized, n))
    @test (s = io(); read!(s, Vector{UInt8}(uninitialized, n)); eof(s))
    n = length(text) + 1
    @test_throws EOFError read!(io(), Vector{UInt8}(uninitialized, n))
    @test_throws EOFError read!(io(), Vector{UInt8}(uninitialized, n))

    old_text = text
    cleanup()

    for text_ in [
        old_text,
        String(Char['A' + i % 52 for i in 1:(div(Base.SZ_UNBUFFERED_IO,2))]),
        String(Char['A' + i % 52 for i in 1:(    Base.SZ_UNBUFFERED_IO -1)]),
        String(Char['A' + i % 52 for i in 1:(    Base.SZ_UNBUFFERED_IO   )]),
        String(Char['A' + i % 52 for i in 1:(    Base.SZ_UNBUFFERED_IO +1)])
    ]
        text = text_
        write(filename, text)

        verbose && println("$name read(io, String)...")
        @test read(io(), String) == text

        @test read(io(), String) == read(filename, String)


        verbose && println("$name read...")
        @test read(io()) == unsafe_wrap(Vector{UInt8},text)

        @test read(io()) == read(filename)

        cleanup()


        verbose && println("$name readbytes!...")
        l = length(text)
        for n = [1, 2, l-2, l-1, l, l+1, l+2]
            a1 = Vector{UInt8}(uninitialized, n)
            a2 = Vector{UInt8}(uninitialized, n)
            s1 = io()
            s2 = IOBuffer(text)
            n1 = readbytes!(s1, a1)
            n2 = readbytes!(s2, a2)
            @test n1 == n2
            @test length(a1) == length(a2)
            @test a1[1:n1] == a2[1:n2]
            @test n <= length(text) || eof(s1)
            @test n <= length(text) || eof(s2)

            cleanup()
        end

        verbose && println("$name read!...")
        l = length(text)
        for n = [1, 2, l-2, l-1, l]
            @test read!(io(), Vector{UInt8}(uninitialized, n)) ==
                  read!(IOBuffer(text), Vector{UInt8}(uninitialized, n))
            @test read!(io(), Vector{UInt8}(uninitialized, n)) ==
                  read!(filename, Vector{UInt8}(uninitialized, n))

            cleanup()
        end
        @test_throws EOFError read!(io(), Vector{UInt8}(uninitialized, length(text)+1))


        verbose && println("$name readuntil...")
        @test readuntil(io(), '\n') == readuntil(IOBuffer(text),'\n')
        @test readuntil(io(), '\n') == readuntil(filename,'\n')
        @test readuntil(io(), "\n") == readuntil(IOBuffer(text),"\n")
        @test readuntil(io(), "\n") == readuntil(filename,"\n")
        @test readuntil(io(), ',')  == readuntil(IOBuffer(text),',')
        @test readuntil(io(), ',')  == readuntil(filename,',')

        cleanup()

        verbose && println("$name readline...")
        @test readline(io(), chomp=false) == readline(IOBuffer(text), chomp=false)
        @test readline(io(), chomp=false) == readline(filename, chomp=false)

        verbose && println("$name readlines...")
        @test readlines(io(), chomp=false) == readlines(IOBuffer(text), chomp=false)
        @test readlines(io(), chomp=false) == readlines(filename, chomp=false)
        @test readlines(io()) == readlines(IOBuffer(text))
        @test readlines(io()) == readlines(filename)
        @test collect(eachline(io(), chomp=false)) == collect(eachline(IOBuffer(text), chomp=false))
        @test collect(eachline(io(), chomp=false)) == collect(eachline(filename, chomp=false))
        @test collect(eachline(io())) == collect(eachline(IOBuffer(text)))
        @test collect(@inferred(eachline(io()))) == collect(@inferred(eachline(filename))) #20351

        cleanup()

        verbose && println("$name countlines...")
        @test countlines(io()) == countlines(IOBuffer(text))

        verbose && println("$name readdlm...")
        @test readdlm(io(), ',') == readdlm(IOBuffer(text), ',')
        @test readdlm(io(), ',') == readdlm(filename, ',')

        cleanup()
    end

    text = old_text
    write(filename, text)

    if !(typeof(io()) in [Base.PipeEndpoint, Pipe, TCPSocket])
        verbose && println("$name position...")
        @test (s = io(); read!(s, Vector{UInt8}(uninitialized, 4)); position(s))  == 4

        verbose && println("$name seek...")
        for n = 0:length(text)-1
            @test readlines(seek(io(), n)) == readlines(seek(IOBuffer(text), n))
            cleanup()
        end
        verbose && println("$name skip...")
        for n = 0:length(text)-1
            @test readlines(seek(io(), n)) == readlines(seek(IOBuffer(text), n))
            @test readlines(skip(io(), n)) == readlines(skip(IOBuffer(text), n))
            cleanup()
        end
        verbose && println("$name seekend...")
        @test read(seekend(io()), String) == ""
    end


    verbose && println("$name write(::IOStream, ...)")
    to = open("$filename.to", "w")
    write(to, io())
    close(to)
    @test read("$filename.to", String) == text

    verbose && println("$name write(filename, ...)")
    write("$filename.to", io())
    @test read("$filename.to", String) == text

    verbose && println("$name write(::IOBuffer, ...)")
    to = IOBuffer(Vector{UInt8}(codeunits(text)), false, true)
    write(to, io())
    @test String(take!(to)) == text

    cleanup()
end

function test_read_nbyte()
    fn = tempname()
    # Write one byte. One byte read should work once
    # but 2-byte read should throw EOFError.
    open(fn, "w+") do f
        write(f, 0x55)
        flush(f)
        seek(f, 0)
        @test read(f, UInt8) == 0x55
        @test_throws EOFError read(f, UInt8)
        seek(f, 0)
        @test_throws EOFError read(f, UInt16)
    end
    # Write 2 more bytes. Now 2-byte read should work once
    # but 4-byte read should fail with EOFError.
    open(fn, "a+") do f
        write(f, 0x4444)
        flush(f)
        seek(f, 0)
        @test read(f, UInt16) == 0x4455
        @test_throws EOFError read(f, UInt16)
        seek(f, 0)
        @test_throws EOFError read(f, UInt32)
    end
    # Write 4 more bytes. Now 4-byte read should work once
    # but 8-byte read should fail with EOFError.
    open(fn, "a+") do f
        write(f, 0x33333333)
        flush(f)
        seek(f, 0)
        @test read(f, UInt32) == 0x33444455
        @test_throws EOFError read(f, UInt32)
        seek(f, 0)
        @test_throws EOFError read(f, UInt64)
    end
    # Writing one more byte should allow an 8-byte
    # read to proceed.
    open(fn, "a+") do f
        write(f, 0x22)
        flush(f)
        seek(f, 0)
        @test read(f, UInt64) == 0x2233333333444455
    end
    rm(fn)
end
test_read_nbyte()


# DevNull
@test !isreadable(DevNull)
@test iswritable(DevNull)
@test isopen(DevNull)
@test write(DevNull, 0xff) === 1
@test write(DevNull, Int32(1234)) === 4
@test_throws EOFError read(DevNull, UInt8)
@test close(DevNull) === nothing
@test flush(DevNull) === nothing
@test eof(DevNull)
@test print(DevNull, "go to /dev/null") === nothing


let s = "qwerty"
    @test read(IOBuffer(s)) == codeunits(s)
    @test read(IOBuffer(s), 10) == codeunits(s)
    @test read(IOBuffer(s), 1) == codeunits(s)[1:1]

    # Test growing output array
    x = UInt8[]
    n = readbytes!(IOBuffer(s), x, 10)
    @test x == codeunits(s)
    @test n == length(x)
end


# Filesystem.File
f = joinpath(dir, "test.txt")
open(io->write(io, "123"), f, "w")
f1 = open(f)
f2 = Base.Filesystem.open(f, Base.Filesystem.JL_O_RDONLY)
@test read(f1, UInt8) == read(f2, UInt8) == UInt8('1')
@test read(f1, UInt8) == read(f2, UInt8) == UInt8('2')
@test read(f1, UInt8) == read(f2, UInt8) == UInt8('3')
@test_throws EOFError read(f1, UInt8)
@test_throws EOFError read(f2, UInt8)
close(f1)
close(f2)

a = UInt8[0,0,0]
f1 = open(f)
f2 = Base.Filesystem.open(f, Base.Filesystem.JL_O_RDONLY)
@test read!(f1, a) == read!(f2, a) == UInt8['1','2','3']
@test_throws EOFError read!(f1, a)
@test_throws EOFError read!(f2, a)
close(f1)
close(f2)

a = UInt8[0,0,0,0]
f1 = open(f)
f2 = Base.Filesystem.open(f, Base.Filesystem.JL_O_RDONLY)
@test_throws EOFError read!(f1, a)
@test_throws EOFError read!(f2, a)
close(f1)
close(f2)
rm(f)

io = Base.Filesystem.open(f, Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_EXCL, 0o000)
@test write(io, "abc") == 3
close(io)
if !Sys.iswindows() && get(ENV, "USER", "") != "root" && get(ENV, "HOME", "") != "/root"
    # msvcrt _wchmod documentation states that all files are readable,
    # so we don't test that it correctly set the umask on windows
    @test_throws SystemError open(f)
    @test_throws Base.UVError Base.Filesystem.open(f, Base.Filesystem.JL_O_RDONLY)
else
    Sys.iswindows() || @warn "File permissions tests skipped due to running tests as root (not recommended)"
    close(open(f))
end
chmod(f, 0o400)
f1 = open(f)
f2 = Base.Filesystem.open(f, Base.Filesystem.JL_O_RDONLY)
for i = 1:2
    @test !eof(f1)
    @test !eof(f2)
    @test position(f1) == 0
    @test position(f2) == 0
    @test read(f1, String) == read(f2, String) == "abc"
    @test read(f1, String) == read(f2, String) == ""
    @test position(f1) == 3
    @test position(f2) == 3
    @test eof(f1)
    @test eof(f2)
    @test seekstart(f1) == f1
    @test seekstart(f2) == f2
end
@test seekend(f1) == f1
@test seekend(f2) == f2
@test eof(f1)
@test eof(f2)
@test skip(f1, -2) == f1
@test skip(f2, -2) == f2
@test position(f1) == 1
@test position(f2) == 1
@test_throws SystemError skip(f1, -2)
@test_throws SystemError skip(f2, -2)
@test position(f1) == 1
@test position(f2) == 1
@test skip(f1, 300) == f1
@test skip(f2, 300) == f2
@test position(f1) == 301
@test position(f2) == 301
@test eof(f1)
@test eof(f2)
@test_throws ArgumentError write(f1, '*')
@test_throws Base.UVError write(f2, '*')
close(f1)
close(f2)
@test eof(f1)
@test_throws Base.UVError eof(f2)
if get(ENV, "USER", "") != "root" && get(ENV, "HOME", "") != "/root"
    @test_throws SystemError open(f, "r+")
    @test_throws Base.UVError Base.Filesystem.open(f, Base.Filesystem.JL_O_RDWR)
else
    @warn "File permissions tests skipped due to running tests as root (not recommended)"
end
chmod(f, 0o600)
f1 = open(f, "r+")
f2 = Base.Filesystem.open(f, Base.Filesystem.JL_O_RDWR)
@test skip(f1, 10) == f1
@test skip(f2, 10) == f2
@test eof(f1)
@test eof(f2)
@test write(f1, '*') == 1
@test flush(f1) === nothing
@test !eof(f2)
@test skip(f2, 1) == f2
@test write(f2, '*') == 1
@test !eof(f1)
@test seekstart(f1) == f1
@test seekstart(f2) == f2
@test read(f1, String) == read(f2, String) == "abc\0\0\0\0\0\0\0**"
close(f1)
close(f2)
rm(f)

end # mktempdir() do dir

@testset "countlines" begin
    @test countlines(IOBuffer("\n")) == 1
    @test countlines(IOBuffer("\n"),'\r') == 0
    @test countlines(IOBuffer("\n\n\n\n\n\n\n\n\n\n")) == 10
    @test countlines(IOBuffer("\n \n \n \n \n \n \n \n \n \n")) == 10
    @test countlines(IOBuffer("\r\n \r\n \r\n \r\n \r\n")) == 5
    file = tempname()
    write(file,"Spiffy header\nspectacular first row\neven better 2nd row\nalmost done\n")
    @test countlines(file) == 4
    @test countlines(file,'\r') == 0
    @test countlines(file,'\n') == 4
    rm(file)
end

let p = Pipe()
    Base.link_pipe(p, julia_only_read=true, julia_only_write=true)
    t = @schedule read(p)
    @sync begin
        @async write(p, fill(UInt16(0), 660_000))
        for i = 1:typemax(UInt16)
            @async write(p, UInt16(i))
        end
        @async close(p.in)
    end
    s = reinterpret(UInt16, wait(t))
    @test length(s) == 660_000 + typemax(UInt16)
    @test s[(end - typemax(UInt16)):end] == UInt16.(0:typemax(UInt16))
end
