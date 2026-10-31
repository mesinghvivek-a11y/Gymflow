import {redirect} from "next/navigation";
import {hasSupabaseConfig} from "@/lib/env";
export default function Home(){if(!hasSupabaseConfig()) redirect("/setup");redirect("/app");}
