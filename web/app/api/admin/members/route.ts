import { createAdminMembersHandlers, defaultAdminMembersDependencies } from "./handlers";

export const { GET, POST, DELETE } = createAdminMembersHandlers(defaultAdminMembersDependencies);
