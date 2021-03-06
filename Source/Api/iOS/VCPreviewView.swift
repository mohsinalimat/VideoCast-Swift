//
//  VCPreviewView.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import UIKit
import GLKit

open class VCPreviewView: UIView {
    private var renderBuffer: GLuint = 0
    private var shaderProgram: GLuint = 0
    private var vbo: GLuint = 0
    private var fbo: GLuint = 0
    private var vao: GLuint = 0
    private var matrixPos: GLuint = 0
    
    private var currentBuffer: Int = 1
    
    private var paused: Atomic<Bool> = .init(false)
    
    private var current: [CVPixelBuffer?] = .init(repeating: nil, count: 2)
    private var cache: CVOpenGLESTextureCache?
    private var texture: [CVOpenGLESTexture?] = .init(repeating: nil, count: 2)
    
    private var context: EAGLContext?
    private var glLayer: CAEAGLLayer?
    
    override open class var layerClass: AnyClass {
        get {
            return CAEAGLLayer.self
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        initInternal()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        initInternal()
    }
    
    private func initInternal() {
        // Initialization code
        glLayer = layer as? CAEAGLLayer
        
        Logger.debug("Creating context")
        context = EAGLContext(api: .openGLES2)
        
        if context == nil {
            Logger.error("Context creation failed")
        }
        autoresizingMask = UIViewAutoresizing(rawValue: 0xFF)
        
        DispatchQueue.main.async { [weak self] in
            self?.setupGLES()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(type(of: self).notification(notification:)), name: .UIApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(type(of: self).notification(notification:)), name: .UIApplicationWillEnterForeground, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        if shaderProgram != 0 {
            glDeleteProgram(shaderProgram)
        }
        if vbo != 0 {
            glDeleteBuffers(1, &vbo)
        }
        if fbo != 0 {
            glDeleteFramebuffers(1, &fbo)
        }
        if renderBuffer != 0 {
            glDeleteRenderbuffers(1, &renderBuffer)
        }
        if let cache = cache {
            CVOpenGLESTextureCacheFlush(cache, 0)
        }
        
        context = nil
    }
    
    open override func layoutSubviews() {
        backgroundColor = .black
        generateGLESBuffers()
    }
    
    @objc private func notification(notification: Notification) {
        switch notification.name {
        case .UIApplicationDidEnterBackground:
            paused.value = true
        case .UIApplicationWillEnterForeground:
            paused.value = false
        default:
            break
        }
    }
    
    open func drawFrame(pixelBuffer: CVPixelBuffer) {
        guard !paused.value else { return }
        
        var updateTexture = false
        
        if pixelBuffer != current[currentBuffer] {
            // not found, swap buffers.
            currentBuffer = (currentBuffer + 1) % 2
        }
        
        if pixelBuffer != current[currentBuffer] {
            // Still not found, update the texture for this buffer.
            current[currentBuffer] = pixelBuffer
            updateTexture = true
        }
        let _currentBuffer = self.currentBuffer
        
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self else { return }
            guard let buffer = strongSelf.current[_currentBuffer],
                let cache = strongSelf.cache else {
                    Logger.debug("unexpected return")
                    return
            }
            
            let current = EAGLContext.current()
            EAGLContext.setCurrent(strongSelf.context)
            
            if updateTexture {
                // create a new texture
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                             cache,
                                                             buffer,
                                                             nil,
                                                             GLenum(GL_TEXTURE_2D),
                                                             GL_RGBA,
                                                             GLsizei(CVPixelBufferGetWidth(buffer)),
                                                             GLsizei(CVPixelBufferGetHeight(buffer)),
                                                             GLenum(GL_BGRA),
                                                             GLenum(GL_UNSIGNED_BYTE),
                                                             0,
                                                             &strongSelf.texture[_currentBuffer])
                guard let texture = strongSelf.texture[_currentBuffer] else {
                    Logger.debug("unexpected return")
                    return
                }
                
                glBindTexture(GLenum(GL_TEXTURE_2D),
                              CVOpenGLESTextureGetName(texture))
                glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLfloat(GL_LINEAR))
                glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLfloat(GL_LINEAR))
                glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
                glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
                
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            guard let texture = strongSelf.texture[_currentBuffer] else {
                Logger.debug("unexpected return")
                return
            }
            
            // draw
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), strongSelf.fbo)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            glBindTexture(GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(texture))
            
            let width = Float(CVPixelBufferGetWidth(buffer))
            let height = Float(CVPixelBufferGetHeight(buffer))
            
            var wfac = Float(strongSelf.bounds.size.width) / width
            var hfac = Float(strongSelf.bounds.size.height) / height
            
            let aspectFit = false
            
            let mult = (aspectFit ? (wfac < hfac) : (wfac > hfac)) ? wfac : hfac
            
            wfac = width*mult / Float(strongSelf.bounds.size.width)
            hfac = height*mult / Float(strongSelf.bounds.size.height)
            
            let matrix = GLKMatrix4ScaleWithVector3(GLKMatrix4Identity, GLKVector3Make(1 * wfac, -1 * hfac, 1))
            
            glUniformMatrix4fv(GLint(strongSelf.matrixPos), 1, GLboolean(GL_FALSE), matrix.array)
            glDrawArrays(GLenum(GL_TRIANGLES), 0, 6)
            glErrors()
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), strongSelf.renderBuffer)
            if !strongSelf.paused.value {
                strongSelf.context?.presentRenderbuffer(Int(GL_RENDERBUFFER))
            }
            EAGLContext.setCurrent(current)
            CVOpenGLESTextureCacheFlush(cache, 0)
        }
        
    }
    
    private func generateGLESBuffers() {
        guard let glLayer = glLayer else {
            Logger.debug("unexpected return")
            return
        }
        
        let current = EAGLContext.current()
        EAGLContext.setCurrent(context)
        
        if renderBuffer != 0 {
            glDeleteRenderbuffers(1, &renderBuffer)
        }
        if fbo != 0 {
            glDeleteFramebuffers(1, &fbo)
        }
        glGenRenderbuffers(1, &renderBuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), renderBuffer)
        
        context?.renderbufferStorage(Int(GL_RENDERBUFFER), from: glLayer)
        
        glErrors()
        
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        var width: GLint = 0, height: GLint = 0
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &width)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &height)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), renderBuffer)
        glErrors()
        
        glClearColor(0, 0, 0, 1)
        
        glViewport(0, 0, GLsizei(glLayer.bounds.size.width), GLsizei(glLayer.bounds.size.height))
        
        EAGLContext.setCurrent(current)
    }
    
    private func setupGLES() {
        guard let context = context else {
            Logger.debug("unexpected return")
            return
        }
        
        let current = EAGLContext.current()
        EAGLContext.setCurrent(context)
        CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, context, nil, &cache)
        
        glGenVertexArraysOES(1, &vao)
        glBindVertexArrayOES(vao)
        
        glGenBuffers(1, &vbo)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
        glBufferData(GLenum(GL_ARRAY_BUFFER), MemoryLayout<GLfloat>.size*s_vbo.count, s_vbo, GLenum(GL_STATIC_DRAW))
        
        shaderProgram = buildProgram(vertex: s_vs_mat, fragment: s_fs)
        glUseProgram(shaderProgram)
        
        let attrpos = glGetAttribLocation(shaderProgram, "aPos")
        let attrtex = glGetAttribLocation(shaderProgram, "aCoord")
        let unitex = glGetUniformLocation(shaderProgram, "uTex0")
        
        matrixPos = GLuint(glGetUniformLocation(shaderProgram, "uMat"))
        
        glUniform1i(unitex, 0)
        
        glEnableVertexAttribArray(GLuint(attrpos))
        glEnableVertexAttribArray(GLuint(attrtex))
        glVertexAttribPointer(GLuint(attrpos), 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), GLsizei(MemoryLayout<Float>.size * 4), BUFFER_OFFSET(0))
        glVertexAttribPointer(GLuint(attrtex), 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), GLsizei(MemoryLayout<Float>.size * 4), BUFFER_OFFSET(8))
        
        EAGLContext.setCurrent(current)
    }
}
