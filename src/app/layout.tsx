import type { Metadata, Viewport } from "next";
import "./globals.css";
export const metadata:Metadata={title:"GymFlow — Gym Management",description:"Membership, collections and gym operations in one workspace.",manifest:"/manifest.webmanifest"};
export const viewport:Viewport={themeColor:"#101a15",width:"device-width",initialScale:1,maximumScale:1,userScalable:false};
export default function RootLayout({children}:{children:React.ReactNode}){return <html lang="en"><body>{children}</body></html>;}
