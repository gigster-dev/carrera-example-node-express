import * as express from 'express';
import { MicroframeworkLoader, MicroframeworkSettings } from 'microframework-w3tec';

import { env } from '../env';
/**
 * EXPRESS TYPESCRIPT BOILERPLATE
 * ----------------------------------------
 *
 * This is a boilerplate for Node.js Application written in TypeScript.
 * The basic layer of this app is express. For further information visit
 * the 'README.md' file.
 */export const homeLoader: MicroframeworkLoader = (settings: MicroframeworkSettings | undefined) => {
    if (settings) {
        const expressApp = settings.getData('express_app');
        expressApp.get(
            env.app.routePrefix,
            (req: express.Request, res: express.Response) => {
                return res.json({
                    name: env.app.name,
                    version: env.app.version,
                    description: env.app.description,
                });
            }
        );

    }
};
