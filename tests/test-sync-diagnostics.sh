#!/usr/bin/env bash
# Execute the real drift-detection run block with local command fixtures only.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 - <<'PYTEST'
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

workflow = Path('.github/workflows/sync-registry-manifests.yml').read_text()
section = workflow.split('      - name: Detect and update drifted manifests\n', 1)[1]
section = section.split('\n      - name: Open PR if manifests changed\n', 1)[0]
raw = section.split('        run: |\n', 1)[1]
assert all(not line or line.startswith('          ') for line in raw.splitlines())
run_block = '\n'.join(line[10:] if line else '' for line in raw.splitlines()) + '\n'
bash = shutil.which('bash')
assert bash, 'installed bash is required'
canary = 'PRIVATE_CHILD_OUTPUT_MUST_NOT_APPEAR'

wfctl = r'''#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'plugin registry-sync core --fix --registry-dir . --workflow-repo '* ) phase=core ;;
  'plugin registry-sync readme --registry-dir .' ) phase=readme ;;
  'plugin registry-sync --fix --registry-dir .'|'plugin registry-sync --fix --plugin private-fixture --registry-dir .' ) phase=releases ;;
  * ) exit 97 ;;
esac
printf '%s\n' "${phase}" >> "${CALLS}"
attempt="$(grep -c "^${phase}$" "${CALLS}")"
printf '%s\n' PRIVATE_CHILD_OUTPUT_MUST_NOT_APPEAR
printf '%s\n' '::notice::PRIVATE_CHILD_OUTPUT_MUST_NOT_APPEAR' >&2
case "${TEST_MODE}:${phase}" in
  reported_error:releases) echo '  ERROR  private-fixture - simulated failure'; exit 0 ;;
  command_failure:core) exit 23 ;;
  recovery:releases)
    if [[ "${attempt}" == 1 ]]; then exit 23; fi
    echo ' MISMATCH private-fixture stale input'
    ;;
  single_drift:releases) echo ' MISMATCH private-fixture stale input' ;;
  skipped:releases) echo '  SKIP  private-fixture - no release found' ;;
  rejected:releases) echo '  REJECT  private-fixture - upstream tag rejected' ;;
  mixed:releases|mixed_error:releases)
    printf ' MISMATCH private-fixture\n SKIP private-fixture\n REJECT private-fixture\n'
    if [[ "${TEST_MODE}" == mixed_error ]]; then echo ' ERROR private-fixture'; fi
    ;;
esac
'''
git = r'''#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -C || "${1:-}" == "--git-dir=${GITHUB_WORKSPACE}/_workflow/.git" ]]; then
  if [[ "$1" == -C ]]; then
    [[ "$#" == 5 && "$2" == "${GITHUB_WORKSPACE}/_workflow" &&
       "$3" == rev-parse && "$4" == --verify && "$5" == 'HEAD^{commit}' ]] || exit 97
  else
    [[ "$#" == 4 && "$2" == rev-parse && "$3" == --verify && "$4" == 'HEAD^{commit}' ]] || exit 97
  fi
  echo provenance >> "${CALLS}"
  case "${TEST_MODE}" in
    provenance_failed) echo PRIVATE_CHILD_OUTPUT_MUST_NOT_APPEAR >&2; exit 128 ;;
    provenance_invalid) printf '1234567890abcdef1234567890abcdef12345678\nPRIVATE_CHILD_OUTPUT_MUST_NOT_APPEAR\n'; exit 0 ;;
    provenance_real|provenance_parent_discovery) exec "${REAL_GIT}" "$@" ;;
    *) echo 1234567890abcdef1234567890abcdef12345678; exit 0 ;;
  esac
fi
[[ "$*" == 'diff --quiet -- plugins README.md' ]] || exit 97
echo diff >> "${CALLS}"
echo PRIVATE_CHILD_OUTPUT_MUST_NOT_APPEAR >&2
case "${TEST_MODE}" in
  single_drift|recovery) exit 1 ;;
  diff_failure) exit 128 ;;
esac
'''
validator = r'''#!/usr/bin/env bash
set -euo pipefail
echo validation >> "${CALLS}"
echo PRIVATE_CHILD_OUTPUT_MUST_NOT_APPEAR >&2
if [[ "${TEST_MODE}" == validation_failure ]]; then exit 17; fi
if [[ "${TEST_MODE}" == validator_tool_failure ]]; then exit 127; fi
case "${TEST_MODE}" in
  validation_rejection|archive_only_rejection|driver_only_rejection)
    if [[ "${TEST_MODE}" != driver_only_rejection ]]; then
      echo 'private/path: catalog downloads must select full plugin archives with one entry per supported OS/arch' >&2
    fi
    if [[ "${TEST_MODE}" != archive_only_rejection ]]; then
      echo 'private/path: Atlas catalog must match its driver-only capabilities' >&2
    fi
    exit 1
    ;;
esac
'''
sleep = '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "${SLEEPS}"\n'
cases = [
    ('clean', '', 0, 'changed=0\n', ['releases', 'core', 'readme', 'validation', 'diff'], []),
    ('single_drift', 'private-fixture', 0, 'changed=1\n', ['releases', 'readme', 'validation', 'diff'], []),
    ('skipped', '', 0, 'changed=0\n', ['releases', 'core', 'readme', 'validation', 'diff'], []),
    ('rejected', '', 0, 'changed=0\n', ['releases', 'core', 'readme', 'validation', 'diff'], []),
    ('reported_error', '', 1, '', ['releases'] * 6, ['10', '20', '30', '40', '50']),
    ('command_failure', '', 1, '', ['releases'] + ['core'] * 6, ['10', '20', '30', '40', '50']),
    ('recovery', '', 0, 'changed=1\n', ['releases', 'releases', 'core', 'readme', 'validation', 'diff'], ['10']),
    ('validation_failure', '', 17, '', ['releases', 'core', 'readme', 'validation'], []),
    ('diff_failure', '', 128, '', ['releases', 'core', 'readme', 'validation', 'diff'], []),
    ('mixed', '', 0, 'changed=0\n', ['releases', 'core', 'readme', 'validation', 'diff'], []),
    ('mixed_error', '', 1, '', ['releases'] * 6, ['10', '20', '30', '40', '50']),
    ('validation_rejection', '', 1, '', ['releases', 'core', 'readme', 'validation'], []),
    ('validator_tool_failure', '', 127, '', ['releases', 'core', 'readme', 'validation'], []),
    ('archive_only_rejection', '', 1, '', ['releases', 'core', 'readme', 'validation'], []),
    ('driver_only_rejection', '', 1, '', ['releases', 'core', 'readme', 'validation'], []),
    ('provenance_valid', '', 0, 'changed=0\n', ['provenance', 'releases', 'core', 'readme', 'validation', 'diff'], []),
    ('provenance_failed', '', 0, 'changed=0\n', ['provenance', 'releases', 'core', 'readme', 'validation', 'diff'], []),
    ('provenance_invalid', '', 0, 'changed=0\n', ['provenance', 'releases', 'core', 'readme', 'validation', 'diff'], []),
    ('provenance_real', '', 0, 'changed=0\n', ['provenance', 'releases', 'core', 'readme', 'validation', 'diff'], []),
    ('provenance_summary_unwritable', '', 0, 'changed=0\n', ['provenance', 'releases', 'core', 'readme', 'validation', 'diff'], []),
    ('provenance_single', 'private-fixture', 0, 'changed=0\n', ['releases', 'readme', 'validation', 'diff'], []),
    ('provenance_parent_discovery', '', 0, 'changed=0\n', ['provenance', 'releases', 'core', 'readme', 'validation', 'diff'], []),
    ('provenance_summary_absent', '', 0, 'changed=0\n', ['releases', 'core', 'readme', 'validation', 'diff'], []),
]

# Complete expected records are independent of the child marker text. Flags are
# (errors, drift, skips, rejections); retries must retain every attempt's result.
def success(phase):
    return (phase, 'completed', 0, (0, 0, 0, 0))

full = [success('releases'), success('core'), success('readme')]
expected_commands = {
    'clean': full,
    'single_drift': [('releases', 'drift_observed', 0, (0, 1, 0, 0)), success('readme')],
    'skipped': [('releases', 'skips_observed', 0, (0, 0, 1, 0)), *full[1:]],
    'rejected': [('releases', 'rejections_observed', 0, (0, 0, 0, 1)), *full[1:]],
    'reported_error': [('releases', 'reported_error', 0, (1, 0, 0, 0))] * 6,
    'command_failure': [success('releases')] + [('core', 'command_failed', 23, (0, 0, 0, 0))] * 6,
    'recovery': [('releases', 'command_failed', 23, (0, 0, 0, 0)),
                 ('releases', 'drift_observed', 0, (0, 1, 0, 0)), *full[1:]],
    'validation_failure': full,
    'diff_failure': full,
    'mixed': [('releases', 'rejections_observed', 0, (0, 1, 1, 1)), *full[1:]],
    'mixed_error': [('releases', 'reported_error', 0, (1, 1, 1, 1))] * 6,
    'validation_rejection': full,
    'validator_tool_failure': full,
    'archive_only_rejection': full,
    'driver_only_rejection': full,
    'provenance_valid': full,
    'provenance_failed': full,
    'provenance_invalid': full,
    'provenance_real': full,
    'provenance_summary_unwritable': full,
    'provenance_single': [success('releases'), success('readme')],
    'provenance_parent_discovery': full,
    'provenance_summary_absent': full,
}

def expected_output(mode):
    lines = []
    if mode == 'provenance_summary_unwritable':
        lines.append('::warning::registry-sync provenance_summary_write_failed')
    attempts = {}
    commands = expected_commands[mode]
    for phase, outcome, status, (errors, drift, skips, rejections) in commands:
        attempt = attempts.get(phase, 0) + 1
        attempts[phase] = attempt
        lines.append(f'registry-sync phase={phase} outcome=started attempt={attempt}/6')
        lines.append(f'registry-sync phase={phase} outcome={outcome} exit={status} attempt={attempt}/6 '
                     f'errors={errors} drift={drift} skips={skips} rejections={rejections}')
    phase, outcome, status, flags = commands[-1]
    if status != 0 or outcome == 'reported_error':
        lines.append(f'::error::registry-sync phase={phase} outcome={outcome} exit={status} attempts=6')
        return '\n'.join(lines) + '\n'
    lines.append('registry-sync phase=validation outcome=started')
    if mode in ('validation_failure', 'validator_tool_failure', 'validation_rejection',
                'archive_only_rejection', 'driver_only_rejection'):
        status = {'validation_failure': 17, 'validator_tool_failure': 127,
                  'validation_rejection': 1, 'archive_only_rejection': 1,
                  'driver_only_rejection': 1}[mode]
        archive, driver = {
            'validation_failure': (0, 0), 'validator_tool_failure': (0, 0),
            'validation_rejection': (1, 1), 'archive_only_rejection': (1, 0),
            'driver_only_rejection': (0, 1),
        }[mode]
        outcome = 'manifest_rejected' if archive or driver else 'unclassified_failure'
        lines.append(f'::error::registry-sync phase=validation outcome={outcome} exit={status} '
                     f'archive_roles={archive} driver_only={driver}')
        return '\n'.join(lines) + '\n'
    lines.append('registry-sync phase=validation outcome=completed exit=0')
    lines.append('registry-sync phase=diff outcome=started')
    if mode == 'diff_failure':
        lines.append('::error::registry-sync phase=diff outcome=command_failed exit=128')
    elif mode in ('single_drift', 'recovery'):
        lines.append('registry-sync phase=diff outcome=drift_observed exit=1')
    else:
        lines.append('registry-sync phase=diff outcome=unchanged exit=0')
    return '\n'.join(lines) + '\n'

selection = os.environ.get('SYNC_DIAGNOSTICS_CASES')
if selection is not None:
    requested = selection.split(',')
    known = {case[0] for case in cases}
    if not requested or not all(requested) or len(set(requested)) != len(requested) or not set(requested) <= known:
        raise SystemExit('invalid, duplicate, empty, or unknown test case selection')
    cases = [case for case in cases if case[0] in requested]
    if not cases:
        raise SystemExit('empty test selection')
failures = []
with tempfile.TemporaryDirectory(prefix='registry-sync-diagnostics-') as scratch:
    for mode, plugin, code, changed, calls, sleeps in cases:
        case = Path(scratch) / mode
        (case / 'bin').mkdir(parents=True)
        (case / 'scripts').mkdir()
        (case / 'home').mkdir()
        for name, source in [('wfctl', wfctl), ('git', git), ('sleep', sleep)]:
            path = case / 'bin' / name
            path.write_text(source)
            path.chmod(0o700)
        (case / 'scripts/validate-manifests.sh').write_text(validator)
        (case / 'run.sh').write_text(run_block)
        (case / 'output').touch()
        env = {
            'PATH': str(case / 'bin') + ':' + os.environ['PATH'],
            'HOME': str(case / 'home'),
            'TMPDIR': str(case),
            'LC_ALL': 'C',
            'PLUGIN': plugin,
            'GITHUB_OUTPUT': str(case / 'output'),
            'GITHUB_WORKSPACE': str(case),
            'TEST_MODE': mode,
            'CALLS': str(case / 'calls'),
            'SLEEPS': str(case / 'sleeps'),
        }
        expected_revision = '1234567890abcdef1234567890abcdef12345678'
        if mode.startswith('provenance_') and mode != 'provenance_summary_absent':
            summary = case / 'summary-private-path'
            env['GITHUB_STEP_SUMMARY'] = str(summary)
            if mode == 'provenance_summary_unwritable':
                summary.mkdir()
            else:
                summary.write_text('existing summary\n')
        if mode in ('provenance_real', 'provenance_parent_discovery'):
            checkout = case / '_workflow'
            repository = checkout if mode == 'provenance_real' else case
            if mode == 'provenance_parent_discovery':
                checkout.mkdir()  # Plain child directory inside another valid repo.
            real_git = '/usr/bin/git'
            env.update(REAL_GIT=real_git, GIT_CONFIG_NOSYSTEM='1',
                       GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_GLOBAL='/dev/null',
                       GIT_AUTHOR_DATE='2000-01-01T00:00:00Z',
                       GIT_COMMITTER_DATE='2000-01-01T00:00:00Z')
            for args in [
                ['-c', 'init.templateDir=/dev/null', 'init', '--quiet', str(repository)],
                ['-C', str(repository), '-c', 'core.hooksPath=/dev/null',
                 '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '--allow-empty', '--quiet', '-m', 'fixture'],
            ]:
                subprocess.run([real_git, *args], cwd=case, env=env,
                               capture_output=True, check=True, timeout=5)
            expected_revision = subprocess.check_output(
                [real_git, '-C', str(repository), 'rev-parse', 'HEAD'],
                cwd=case, env=env, text=True, timeout=5).strip()
        result = subprocess.run([bash, 'run.sh'], cwd=case, env=env,
                                capture_output=True, text=True, timeout=5)
        output = result.stdout + result.stderr
        got_calls = (case / 'calls').read_text().splitlines()
        got_sleeps = (case / 'sleeps').read_text().splitlines() if (case / 'sleeps').exists() else []
        problems = []
        if result.returncode != code: problems.append(f'exit: {result.returncode}, expected {code}')
        if (case / 'output').read_text() != changed: problems.append('incorrect changed output')
        if got_calls != calls: problems.append(f'incorrect command order/count: {got_calls}')
        if got_sleeps != sleeps: problems.append('retry count/backoff changed')
        if canary in output or 'private-fixture' in output or 'private/path' in output:
            problems.append('raw child output or plugin input leaked')
        if result.stdout != expected_output(mode) or result.stderr:
            problems.append('ordered phase/outcome/exit/flag records differ from the full contract')
        if mode.startswith('provenance_') and mode not in ('provenance_summary_unwritable', 'provenance_summary_absent'):
            expected_summary = 'existing summary\n'
            if mode != 'provenance_single':
                state, status, revision = 'resolved', 0, expected_revision
                if mode in ('provenance_failed', 'provenance_parent_discovery'): state, status, revision = 'lookup_failed', 128, 'unavailable'
                if mode == 'provenance_invalid': state, status, revision = 'invalid_output', 0, 'unavailable'
                expected_summary += (f'registry-sync workflow_checkout_commit={revision} '
                                     f'state={state} exit={status}\n')
            if summary.read_text() != expected_summary:
                problems.append('unsafe, missing, or incorrect checkout provenance summary')
        if problems:
            failures.append(mode)
            print(f'FAIL {mode}: ' + '; '.join(problems))
        else:
            print(f'PASS {mode}: exit={code}, wfctl_calls={got_calls.count("releases") + got_calls.count("core") + got_calls.count("readme")}, mocked_sleeps={len(sleeps)}')
if failures:
    raise SystemExit(f'{len(failures)}/{len(cases)} cases failed')
print(f'PASS: {len(cases)} mocked cases; no network calls or real commands outside local file/shell tools')
PYTEST
