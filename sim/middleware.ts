import { NextRequest, NextResponse } from 'next/server'
import { getSessionCookie } from 'better-auth/cookies'
import { verifyToken } from './lib/waitlist/token'
import { createLogger } from '@/lib/logs/console-logger'

const logger = createLogger('Middleware')

const isDevelopment = process.env.NODE_ENV === 'development'

// Domains/IPs to treat as dev or allowed
const allowedDomains = [
  'simstudio.ai',
  'simcity1',
  '10.211.55.42',
  '100.78.223.87',
  'localhost',
  '127.0.0.1',
  'host.docker.internal',
  'simstudio.local.ts.net'
]

const tailscalePattern = /\.ts\.net$/i

export async function middleware(request: NextRequest) {
  const url = request.nextUrl
  const hostname = request.headers.get('host') || ''

  const sessionCookie = getSessionCookie(request)
  const hasActiveSession = !!sessionCookie
  const hasPreviouslyLoggedIn = request.cookies.get('has_logged_in_before')?.value === 'true'

  const isDevDomain = allowedDomains.includes(hostname) || tailscalePattern.test(hostname)

  const BASE_DOMAIN = isDevDomain ? 'localhost:3000' : 'simstudio.ai'

  // Handle subdomain-based routing
  const isCustomDomain =
    hostname !== BASE_DOMAIN &&
    !hostname.startsWith('www.') &&
    (hostname.includes('simstudio.ai') || tailscalePattern.test(hostname))

  const subdomain = isCustomDomain ? hostname.split('.')[0] : null

  if (subdomain && isCustomDomain) {
    if (url.pathname.startsWith('/api/chat/')) {
      return NextResponse.next()
    }

    return NextResponse.rewrite(new URL(`/chat/${subdomain}${url.pathname}`, request.url))
  }

  if (url.pathname === '/w') {
    return NextResponse.redirect(new URL('/w/1', request.url))
  }

  if (request.nextUrl.pathname.startsWith('/invite/')) {
    return NextResponse.next()
  }

  if (url.pathname.startsWith('/w/') || url.pathname === '/w') {
    if (!hasActiveSession) {
      return NextResponse.redirect(new URL('/login', request.url))
    }
    return NextResponse.next()
  }

  if (isDevelopment) {
    return NextResponse.next()
  }

  if (hasActiveSession) {
    return NextResponse.next()
  }

  if (url.pathname === '/login' || url.pathname === '/signup') {
    if (hasPreviouslyLoggedIn && request.nextUrl.pathname === '/login') {
      return NextResponse.next()
    }

    const waitlistToken = url.searchParams.get('token')
    const redirectParam = request.nextUrl.searchParams.get('redirect')

    if (redirectParam && redirectParam.startsWith('/invite/')) {
      return NextResponse.next()
    }

    if (waitlistToken) {
      try {
        const decodedToken = await verifyToken(waitlistToken)
        const now = Math.floor(Date.now() / 1000)
        if (decodedToken?.type === 'waitlist-approval' && decodedToken.exp > now) {
          return NextResponse.next()
        }

        if (url.pathname === '/signup') {
          return NextResponse.redirect(new URL('/', request.url))
        }
      } catch (error) {
        logger.error('Token validation error:', error)
        if (url.pathname === '/signup') {
          return NextResponse.redirect(new URL('/', request.url))
        }
      }
    } else {
      if (url.pathname === '/signup') {
        return NextResponse.redirect(new URL('/', request.url))
      }
    }
  }

  const userAgent = request.headers.get('user-agent') || ''
  const SUSPICIOUS_UA_PATTERNS = [
    /^\s*$/,
    /\.\./,
    /<\s*script/i,
    /^\(\)\s*{/,
    /\b(sqlmap|nikto|gobuster|dirb|nmap)\b/i
  ]

  const isSuspicious = SUSPICIOUS_UA_PATTERNS.some(pattern => pattern.test(userAgent))

  if (isSuspicious) {
    logger.warn('Blocked suspicious request', {
      userAgent,
      ip: request.headers.get('x-forwarded-for') || 'unknown',
      url: request.url,
      method: request.method,
      pattern: SUSPICIOUS_UA_PATTERNS.find(p => p.test(userAgent))?.toString()
    })

    return new NextResponse(null, {
      status: 403,
      statusText: 'Forbidden',
      headers: {
        'Content-Type': 'text/plain',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'Content-Security-Policy': "default-src 'none'",
        'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0'
      }
    })
  }

  const response = NextResponse.next()
  response.headers.set('Vary', 'User-Agent')
  return response
}

export const config = {
  matcher: [
    '/w',
    '/w/:path*',
    '/login',
    '/signup',
    '/invite/:path*',
    '/((?!_next/static|_next/image|favicon.ico).*)'
  ]
}
