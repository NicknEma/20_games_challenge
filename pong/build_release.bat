@echo off

rc /nologo res/resources.rc

odin build src -debug -out:pong.exe -vet-shadowing -warnings-as-errors -o:speed -disable-assert -extra-linker-flags:"/subsystem:windows res/resources.res"
del res/resources.res > NUL 2> NUL
