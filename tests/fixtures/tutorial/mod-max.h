#ifndef MOD_MAX_H
#define MOD_MAX_H
/*@ assigns \nothing;
    ensures \result >= a && \result >= b;
    ensures \result == a || \result == b;
*/
int mod_max(int a, int b);
#endif
