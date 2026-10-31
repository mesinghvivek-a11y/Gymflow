export default function WorkspaceLoading() {
  return (
    <div className="page-loading" role="status" aria-label="Loading page">
      <span className="sr-only">Loading workspace</span>
      <div className="loading-heading"><div className="skeleton skeleton-kicker" /><div className="skeleton skeleton-title" /><div className="skeleton skeleton-copy" /></div>
      <div className="loading-metrics">
        {Array.from({ length: 4 }, (_, index) => <div className="skeleton-card" key={index}><div className="skeleton skeleton-label" /><div className="skeleton skeleton-number" /><div className="skeleton skeleton-copy" /></div>)}
      </div>
      <div className="skeleton-panel"><div className="skeleton skeleton-panel-title" />{Array.from({ length: 5 }, (_, index) => <div className="skeleton skeleton-row" key={index} />)}</div>
    </div>
  );
}
