"use client";

import { LoaderCircle } from "lucide-react";
import { useFormStatus } from "react-dom";
import type { ReactNode } from "react";

type Props = {
  children: ReactNode;
  className?: string;
  pendingText?: string;
  disabled?: boolean;
};

/** Immediate feedback for a server-action form while the request is in flight. */
export function SubmitButton({ children, className = "primary-btn", pendingText = "Saving…", disabled = false }: Props) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" className={className} disabled={disabled || pending} aria-busy={pending}>
      {pending ? <><LoaderCircle size={14} className="button-spinner" />{pendingText}</> : children}
    </button>
  );
}
