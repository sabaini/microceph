# CE127 Phase 2 (Snap): WAL/DB matching + automatic partitioning

## Scope

This plan covers **snap-side Phase 2** only:

- `microceph disk add` support for:
  - `--wal-match`
  - `--db-match`
  - `--wal-size`
  - `--db-size`
- automatic partition planning and creation for WAL/DB backing devices
- additive behavior (no partition/device removal)
- dry-run output including partition/assignment plan

Out of scope for this iteration:

- charm integration (`wal-devices`, `db-devices`, etc.)
- additional troubleshooting UX (`disk list` attribute dump, extra verbose/debug actions)

## Agreed behavior decisions

1. Focus on core WAL/DB matching + partitioning first.
2. If `wal-match` / `db-match` evaluate to empty sets, treat as **non-fatal** and continue data-only OSDs.
3. For WAL/DB non-empty backing disks, allow only if `ceph-bluestore-tool show-label` indicates labels from the **current cluster fsid**.
4. Partition tool: **`sgdisk`**.

## Implementation breakdown

### 1) CLI and API contract

- Extend `disk add` flags and validation:
  - `--wal-match`, `--db-match`, `--wal-size`, `--db-size`
  - validate combinations and required size flags for WAL/DB match modes
- Extend REST payload (`DisksPost`) with WAL/DB match/size fields
- Route new fields from CLI -> API -> OSD manager

### 2) DSL matching orchestration

- Keep existing OSD matching flow
- Add reusable matching over custom candidate sets for WAL/DB
- Validate no overlap across OSD/WAL/DB matched block devices

### 3) WAL/DB candidate eligibility

- Build WAL/DB candidate set from local storage resources
- Exclude clearly unsuitable devices (read-only, mounted, data OSD devices)
- Eligibility rules when not using wipe:
  - pristine disk is accepted
  - otherwise accepted only if bluestore labels exist with `ceph_fsid == current cluster fsid`

### 4) Partition planning

- Parse `--wal-size` / `--db-size` using existing DSL unit parser
- For `X` new OSDs, generate exactly `X` WAL and/or DB partitions
- Distribute partitions by minimizing delta in partition counts across backing disks
- Capacity precheck:
  - if total available capacity for a role is insufficient, fail before OSD creation

### 5) Partition creation and assignment

- Create planned partitions with `sgdisk`
- Resolve created partition paths and assign one WAL/DB partition per OSD (same index mapping)
- Create OSDs one-by-one with assigned partition paths

### 6) Dry-run output

- Extend dry-run response with:
  - matched WAL/DB devices
  - planned partition creations
  - planned OSD -> WAL/DB assignment map

### 7) Packaging

- Ensure `sgdisk` is available in snap runtime (`gdisk` stage-package + `bin/sgdisk` prime)

### 8) Tests

- Unit-level coverage for:
  - match flag validation
  - overlap detection
  - size parsing
  - planning fairness and capacity failure
- Follow-up functional tests in VM/LXD for end-to-end partition creation path

## Status

- [x] Plan drafted
- [x] Initial implementation started (CLI/API wiring, planner, dry-run, partition creation integration)
- [x] Extended tests for new planner/flow
- [x] Functional test updates for WAL/DB partitioning
- [x] Documentation refresh for command reference/examples

## Notes

- Current implementation intentionally prioritizes core provisioning semantics.
- Additional troubleshooting enhancements are deferred to a follow-up item after Phase 2 core flow stabilizes.
