//T compiles:yes
//T retval:30
//T dependency:test37_import.d

import test37_import;

alias int Integer;
alias test37_import.S SS;
alias foo bar;

int bazoooooooom()
{
    return 2;
}

Integer main()
{
    SS s;
    s.i = 30;
    bar(&s.i);
    return s;
}

