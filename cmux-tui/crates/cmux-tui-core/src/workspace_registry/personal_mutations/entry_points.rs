//! Transaction-owning entry points of the raw `profiles-v1` commands.

use super::*;

impl WorkspaceRegistry {
    pub fn create_profile(
        &mut self,
        input: ProfileInput,
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::create_profile_in(&tx, input)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn update_profile(
        &mut self,
        id: &str,
        update: ProfileUpdate,
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::update_profile_in(&tx, id, update)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn move_profile(
        &mut self,
        id: &str,
        index: usize,
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::move_profile_in(&tx, id, index)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn delete_profile(
        &mut self,
        id: &str,
        move_to: Option<&str>,
    ) -> anyhow::Result<ProfileDeletion> {
        let tx = self.connection.transaction()?;
        let output = Self::delete_profile_in(&tx, id, move_to)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn set_profile_follows(
        &mut self,
        id: &str,
        sessions: &[String],
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::set_profile_follows_in(&tx, id, sessions)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn pin_workspace(
        &mut self,
        session: &str,
        key: &str,
        profile: &str,
    ) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let output = Self::pin_workspace_in(&tx, session, key, profile)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn unpin_workspace(&mut self, session: &str, key: &str) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let output = Self::unpin_workspace_in(&tx, session, key)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn put_session(
        &mut self,
        session: &str,
        machine_name: Option<&str>,
        session_name: Option<&str>,
        transport: &Value,
        capabilities: Option<&Value>,
        follow_with: Option<&str>,
    ) -> anyhow::Result<(PersonalSession, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::put_session_in(
            &tx,
            session,
            machine_name,
            session_name,
            transport,
            capabilities,
            follow_with,
        )?;
        tx.commit()?;
        Ok(output)
    }

    pub fn forget_session(&mut self, session: &str, force: bool) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let output = Self::forget_session_in(&tx, session, force)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn create_personal_group(
        &mut self,
        id: Option<String>,
        profile: Option<&str>,
        name: &str,
        color: Option<&str>,
        collapsed: bool,
        index: Option<usize>,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        let tx = self.connection.transaction()?;
        let output =
            Self::create_personal_group_in(&tx, id, profile, name, color, collapsed, index)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn update_personal_group(
        &mut self,
        id: &str,
        name: Option<&str>,
        color: Option<Option<&str>>,
        collapsed: Option<bool>,
        profile: Option<&str>,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::update_personal_group_in(&tx, id, name, color, collapsed, profile)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn delete_personal_group(&mut self, id: &str) -> anyhow::Result<Vec<(String, String)>> {
        let tx = self.connection.transaction()?;
        let output = Self::delete_personal_group_in(&tx, id)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn move_personal_group(
        &mut self,
        id: &str,
        index: usize,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::move_personal_group_in(&tx, id, index)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn set_personal_workspace(
        &mut self,
        session: &str,
        key: &str,
        update: PersonalWorkspaceUpdate,
    ) -> anyhow::Result<(PersonalWorkspace, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::set_personal_workspace_in(&tx, session, key, update)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn import_session_organization(
        &mut self,
        session: &str,
        groups: &[(String, String, Option<String>, bool)],
        workspaces: &[(String, Option<String>)],
    ) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let output = Self::import_session_organization_in(&tx, session, groups, workspaces)?;
        tx.commit()?;
        Ok(output)
    }
}
