## Deriving the closed form

Let $S_n = \sum_{k=1}^{n} k^2$. We guess $S_n = an^3 + bn^2 + cn$ and match the first three values.

The recurrence gives
$$
S_n - S_{n-1} = n^2
$$
so, expanding $(n-1)^3$ and $(n-1)^2$,

\[
\begin{aligned}
3a &= 1, \\
-3a + 2b &= 0, \\
a - b + c &= 0.
\end{aligned}
\]

Solving: \(a = \tfrac{1}{3}\), \(b = \tfrac{1}{2}\), \(c = \tfrac{1}{6}\), hence

$$S_n = \frac{n(n+1)(2n+1)}{6}.$$

### Check

| $n$ | $S_n$ (sum) | $\frac{n(n+1)(2n+1)}{6}$ |
| --: | --: | --: |
| 1 | 1 | 1 |
| 2 | 5 | 5 |
| 10 | 385 | 385 |

A matrix form also works: the Vandermonde system
$$\begin{pmatrix} 1 & 1 & 1 \\ 8 & 4 & 2 \\ 27 & 9 & 3 \end{pmatrix}\begin{pmatrix} a \\ b \\ c \end{pmatrix} = \begin{pmatrix} 1 \\ 5 \\ 14 \end{pmatrix}$$

Note the growth is $\Theta(n^3)$, and the error of the integral estimate $\int_0^n x^2\,dx = n^3/3$ is $O(n^2)$. A price like $5 or $10 is not math, and neither is `$PATH` or \$HOME.
