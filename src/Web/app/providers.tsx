'use client';

import { useEffect } from 'react';
import { initBrowserOtel } from '@/lib/otel/client';

export function Providers({ children }: { children: React.ReactNode }) {
  useEffect(() => {
    initBrowserOtel();
  }, []);
  return <>{children}</>;
}
