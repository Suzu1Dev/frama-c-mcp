#ifndef MOD_ABS_H
#define MOD_ABS_H
#include <limits.h>
/*@
    requires val > INT_MIN;
    assigns \nothing;
    ensures \result >= 0;
    behavior pos:
        assumes 0 <= val;
        ensures \result == val;
    behavior neg:
        assumes val < 0;
        ensures \result == -val;
    complete behaviors;
    disjoint behaviors;
*/
int mod_abs(int val);
#endif
