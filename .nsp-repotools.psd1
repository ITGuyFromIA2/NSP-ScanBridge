@{
    # Settings for NSP.RepoTools. Tracked: name what is accepted, never a client.
    Publish = @{
        # Agent and handoff documents stay in the repository, not in the module package.
        Exclude = @('docs/CODEX-HANDOFF.md', 'docs/*HANDOFF*', 'AGENTS.md', '*/AGENTS.md')
    }
}
