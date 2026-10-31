import type {MetadataRoute} from "next";
export default function manifest():MetadataRoute.Manifest{return {name:"GymFlow — Gym Management",short_name:"GymFlow",description:"Gym memberships, collections and reminders",start_url:"/app",display:"standalone",background_color:"#f5f7f4",theme_color:"#101a15",icons:[{src:"/icon.svg",sizes:"any",type:"image/svg+xml",purpose:"any maskable"}]};}
