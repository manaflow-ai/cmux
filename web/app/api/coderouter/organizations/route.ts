import { organizationsGet } from "../../subrouter/teams/route";
import { authorizedCoderouterTeams } from "../../../../services/coderouter/permissions";

export async function GET(request: Request): Promise<Response> {
  return organizationsGet(request, authorizedCoderouterTeams);
}
