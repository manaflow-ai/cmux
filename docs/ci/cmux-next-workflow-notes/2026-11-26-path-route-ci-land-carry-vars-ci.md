# path_route: CI_LAND_CARRY: ${{ vars.CI_LAND_CARRY || '1' }}

Where: the `path_route` job in `.github/workflows/cmux-next.yml`, above `CI_LAND_CARRY: ${{ vars.CI_LAND_CARRY || '1' }}`.

A ready-to-land head that only merges the base onto a head whose full tier passed runs the cheap tier and
carries cmux/land-tier success (head_tier.py's land carry rule); 0 turns that off.
