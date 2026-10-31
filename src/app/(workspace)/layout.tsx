import {WorkspaceShell} from "@/components/workspace-shell";
import {requireActiveGym} from "@/lib/workspace";
export const dynamic="force-dynamic";
export default async function WorkspaceLayout({children}:{children:React.ReactNode}){const {gym,email}=await requireActiveGym();return <WorkspaceShell gym={gym} email={email}>{children}</WorkspaceShell>;}
