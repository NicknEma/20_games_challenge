@echo off

rc /nologo res/resources.rc

odin build src -debug -out:pong.exe -vet-shadowing -extra-linker-flags:"res/resources.res"
del res/resources.res > NUL 2> NUL
