# Copilot Instructions — clincher (Ansible)

- Always use FQCN for module names (ansible.builtin., community.docker., etc.)
- All tasks need `name:` descriptions starting with a verb
- Secrets must use ansible-vault; never hardcode credentials
- Prefer `community.docker.docker_container` over `ansible.builtin.command: docker run`
- Every role must have a corresponding Molecule scenario in molecule/<role>/
- Use `become: true` only at the task level, never at the play level
- Shell/command tasks must include `changed_when:` to avoid always-changed
