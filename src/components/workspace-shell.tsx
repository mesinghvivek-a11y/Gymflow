"use client";
import Link from "next/link";
import {usePathname} from "next/navigation";
import type {ReactNode} from "react";
import {BarChart3,CalendarClock,CircleDollarSign,LayoutDashboard,LogOut,MessageSquare,Settings,Users,ClipboardList} from "lucide-react";
import type {GymSummary} from "@/lib/workspace";
import {signOutAction} from "@/server/actions/auth";
const items=[
 {href:"/app",label:"Overview",mobile:"Home",Icon:LayoutDashboard},
 {href:"/app/members",label:"Members",mobile:"Members",Icon:Users},
 {href:"/app/payments",label:"Payments",mobile:"Payments",Icon:CircleDollarSign},
 {href:"/app/dues",label:"Renewals & dues",mobile:"Dues",Icon:CalendarClock},
 {href:"/app/reports",label:"Reports",mobile:"Reports",Icon:BarChart3}
];
export function WorkspaceShell({gym,email,children}:{gym:GymSummary;email:string;children:ReactNode}){
 const pathname=usePathname();const initials=(email.split("@")[0]?.slice(0,2)||"GF").toUpperCase();
 const active=(href:string)=>href==="/app"?pathname===href:pathname.startsWith(href);
 return <div className="workspace"><aside className="sidebar"><div className="sidebar-brand"><span className="brand-mark">G</span><span>gymflow<span style={{color:"var(--green)"}}>.</span></span></div><div className="gym-chip"><small>Workspace</small><strong>{gym.name}</strong><span style={{fontSize:10,color:"#8fa197",display:"block",marginTop:4}}>{gym.timezone}</span></div><div className="nav-label">Manage</div><nav className="nav-list">{items.map(({href,label,Icon})=><Link key={href} href={href} className={`nav-link${active(href)?" active":""}`}><Icon size={17}/>{label}</Link>)}</nav><div className="nav-label" style={{marginTop:24}}>Setup</div><nav className="nav-list"><Link href="/app/plans" className={`nav-link${active("/app/plans")?" active":""}`}><ClipboardList size={17}/>Plans</Link><Link href="/app/memberships" className={`nav-link${active("/app/memberships")?" active":""}`}><CalendarClock size={17}/>Memberships</Link><Link href="/app/messages" className={`nav-link${active("/app/messages")?" active":""}`}><MessageSquare size={17}/>Message centre</Link><Link href="/app/billing" className={`nav-link${active("/app/billing")?" active":""}`}><CircleDollarSign size={17}/>GymFlow billing</Link><Link href="/app/settings" className={`nav-link${active("/app/settings")?" active":""}`}><Settings size={17}/>Settings</Link></nav><div className="sidebar-bottom"><div className="user-row"><span className="avatar">{initials}</span><span style={{overflow:"hidden",textOverflow:"ellipsis"}}>{email||"Gym administrator"}</span></div><form action={signOutAction}><button type="submit" className="signout"><LogOut size={15}/> Sign out</button></form></div></aside><main className="main-area"><header className="topbar"><div className="breadcrumb">Workspace <span style={{padding:"0 7px",color:"#b4beb7"}}>/</span><strong style={{color:"#405047",textTransform:"capitalize"}}>{pathname==="/app"?"Overview":pathname.split("/").filter(Boolean).at(-1)?.replaceAll("-"," ")}</strong></div><div className="topbar-right"><span className="topbar-date">{new Intl.DateTimeFormat("en-IN",{dateStyle:"medium",timeZone:gym.timezone}).format(new Date())}</span></div></header>{children}</main><nav className="mobile-nav">{items.map(({href,mobile,Icon})=><Link key={href} href={href} className={active(href)?"active":""}><Icon size={18}/><span>{mobile}</span></Link>)}</nav></div>;
}
